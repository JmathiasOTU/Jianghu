--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)

local NoclipState = require(script.Parent.Parent.Parent.State.NoclipState)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local Violations = require(script.Parent.Violations)
local SpeedCaps = require(script.Parent.SpeedCaps)

type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- Enforces the horizontal speed budget (docs/MovementSystem.md §8.2):
-- distance accumulated per Heartbeat at the live cap, judged every
-- SpeedCheckIntervalSeconds, and the position corrections that follow.
local SpeedCheck = {}

-- DebugFlags.SPEED_RATIO_CAPTURE's samples (see DebugFlags).
local SPEED_RATIO_REPORT_EVERY = 200
local SPEED_RATIO_MAX_SAMPLES = 20000
local speedRatioSamples: { number } = {}
local speedRatioSinceReport = 0
local zeroBudgetDriftMax = 0

local function recordSpeedRatio(flatDistance: number, budget: number)
	if budget <= 0 then
		zeroBudgetDriftMax = math.max(zeroBudgetDriftMax, flatDistance)
		return
	end
	if #speedRatioSamples < SPEED_RATIO_MAX_SAMPLES then
		table.insert(speedRatioSamples, flatDistance / budget)
	end
	speedRatioSinceReport += 1
	if speedRatioSinceReport < SPEED_RATIO_REPORT_EVERY then
		return
	end
	speedRatioSinceReport = 0

	local sorted = table.clone(speedRatioSamples)
	table.sort(sorted)
	local function percentile(fraction: number): number
		return sorted[math.clamp(math.ceil(fraction * #sorted), 1, #sorted)]
	end
	print(
		string.format(
			"[SpeedRatio] n=%d p50=%.3f p99=%.3f p99.9=%.3f max=%.3f zeroBudgetDriftMax=%.3f studs",
			#sorted,
			percentile(0.5),
			percentile(0.99),
			percentile(0.999),
			sorted[#sorted],
			zeroBudgetDriftMax
		)
	)
end

function SpeedCheck.ResetWindow(session: PlayerSession)
	local now = os.clock()
	session.speedCheckPosition = session.rootPart.Position
	session.speedCheckAt = now
	session.speedBudget = 0
	session.speedBudgetAt = now
end

-- Allows a known, instant horizontal move of up to `distance` studs (the vault
-- snap) in every window that starts by `untilAt`: the snap can replicate just
-- before or after the accept that grants it, and the window can roll over in
-- between. Not scaled by the tolerance -- it's an exact bound, not a speed.
function SpeedCheck.CreditDisplacement(session: PlayerSession, distance: number, untilAt: number)
	session.displacementCredit = distance
	session.displacementCreditUntil = untilAt
end

-- Every server position correction lands here (audit M-008): moves the rig
-- (rotation kept) and kills its velocity, so a cheat snapped back doesn't just
-- resume at full speed the next frame, then restarts the speed window from
-- the corrected position.
function SpeedCheck.CorrectToPosition(session: PlayerSession, position: Vector3)
	local rootPart = session.rootPart
	rootPart.CFrame = (rootPart.CFrame - rootPart.Position) + position
	rootPart.AssemblyLinearVelocity = Vector3.zero
	SpeedCheck.ResetWindow(session)
end

-- Lightweight anti-noclip/speed-hack net (docs/MovementSystem.md §8): not a full
-- predict-validate-correct loop (no raycasts, no world geometry) -- Phase 1 has
-- nothing spatial to validate yet, just "did this player cover more ground than
-- their currently-mirrored tier allows." Sampled over a fixed interval rather than
-- every Heartbeat: per-frame `CFrame` replication from an owning client arrives in
-- bursts, not evenly, so a raw frame-to-frame delta would false-positive on normal
-- replication jitter long before it caught a real speed hack. Vertical (Y) motion
-- is policed separately by `VerticalCeiling.Enforce`.
--
-- The window's allowed distance is a budget accumulated every Heartbeat at the
-- cap live during that Heartbeat (audit M-002), so neither a transition nor a
-- one-shot "exemption" ever discards an unmeasured stretch of movement. The
-- old post-claim suspension window is gone for the same reason: 5 accepted
-- DoubleJump claims a second each suspending the check for 0.5s turned it off.
--
-- Exempted entirely while `NoclipState.IsActive` (docs/MovementSystem.md §10) -- the
-- scouting tool's whole point is to move faster than any tier's cap allows, so
-- without this exemption it would rubber-band the very thing it exists for.
-- Checked against the SERVER's own authorized record, never a client-reported
-- flag (docs/ARCHITECTURE.md §3) -- DevToolsService.luau is the only writer.
function SpeedCheck.Enforce(session: PlayerSession, constants: EffectiveMovementConstants)
	if NoclipState.IsActive(session.player) then
		SpeedCheck.ResetWindow(session)
		return
	end

	local now = os.clock()
	-- The floor's own speed rides on top of the character's cap (audit M-014,
	-- player-vs-player collision kept on): standing on a moving platform or
	-- another player's head carries you along. Only physics-driven motion the
	-- server can vouch for counts (`trustedFloorVelocity`) -- an anchored part
	-- moved by CFrame/tween reports zero.
	session.carrySpeed = SpeedCaps.EffectiveMaxSpeed(session, constants) + session.floorSpeed
	session.speedBudget += session.carrySpeed * (now - session.speedBudgetAt)
	session.speedBudgetAt = now

	local elapsed = now - session.speedCheckAt
	if elapsed < MovementConstants.SpeedCheckIntervalSeconds then
		return
	end

	local position = session.rootPart.Position
	local previous = session.speedCheckPosition
	local flatDelta = Vector3.new(position.X - previous.X, 0, position.Z - previous.Z)
	local credit = 0
	local creditUntil = session.displacementCreditUntil
	if creditUntil then
		if session.speedCheckAt <= creditUntil then
			credit = session.displacementCredit
		else
			session.displacementCreditUntil = nil
		end
	end
	local maxDistance = session.speedBudget * MovementConstants.SpeedToleranceMultiplier + credit

	if DebugFlags.SPEED_RATIO_CAPTURE then
		recordSpeedRatio(flatDelta.Magnitude, session.speedBudget)
	end

	if flatDelta.Magnitude > maxDistance then
		-- `Violations.Report` prints it in Studio (docs/MovementSystem.md §10);
		-- ViolationTracker keeps a bounded history of the detail instead of
		-- only the running count, so DebugBroadcast.Send can show the
		-- overlay's last few corrections, not just how many there have been.
		Violations.Report(session, "Speed", {
			flatDelta = flatDelta.Magnitude,
			maxDistance = maxDistance,
			elapsed = elapsed,
		})

		-- Horizontal-only snap: Y is left to the vertical ceiling, and the
		-- horizontal velocity is killed so the cheat can't simply carry on
		-- (audit M-008).
		local rootPart = session.rootPart
		local corrected = Vector3.new(previous.X, position.Y, previous.Z)
		rootPart.CFrame = (rootPart.CFrame - position) + corrected
		rootPart.AssemblyLinearVelocity = Vector3.new(0, rootPart.AssemblyLinearVelocity.Y, 0)
	end

	SpeedCheck.ResetWindow(session)
end

return SpeedCheck
