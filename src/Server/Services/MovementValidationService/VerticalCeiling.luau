--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)

local NoclipState = require(script.Parent.Parent.Parent.State.NoclipState)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local Violations = require(script.Parent.Violations)
local SpeedCaps = require(script.Parent.SpeedCaps)
local ClaimTiming = require(script.Parent.ClaimTiming)

type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- Vertical ceiling (audit M-001): the highest Y this character can legally
-- reach, built only from server-known impulses. Standing on real ground
-- re-anchors it to "here plus one Humanoid jump"; every accepted vertical move
-- raises it by that move's own maximum rise (`VerticalCeiling.Raise`). Every
-- built-in launch REPLACES vertical velocity rather than adding to it, and the
-- character can't be above the old ceiling when it launches, so old ceiling +
-- rise is a true upper bound whatever the timing.
--
-- Descent (re-audit N-001/N-002): the ceiling is also a point in time. Each
-- launch records when it stops rising (`verticalApexAt`); after that an
-- unsupported character with nothing holding it up must be falling from the
-- ceiling at least as fast as gravity (`TraversalMath.DescentCeiling`), so it
-- can't hover or float down. This is also what ends a WallLeap speed
-- allowance: the leap's flight has to come down, and the landing clears it.
-- The ceiling re-anchors whenever the server's own support probe finds real
-- ground under the feet, whatever the Humanoid label says (2026-09-24
-- playtest capture): the label is client-written and reaches the server
-- ahead of the position stream, so anchoring on "label says grounded" froze
-- the anchor ~0.15-0.2s before the observed takeoff, and ordinary jumps were
-- judged from a stale, lower point. Standing on geometry is what makes "one
-- jump from here" legal; the label adds nothing. A correction never puts the
-- root below standing height on the floor under it
-- (`SpatialQueries.QueryFloorBelow`), so a missed support read can at worst
-- set the character down on the floor, never into it.
--
-- Replication ordering: the position stream and the claim that justifies a
-- rise or a hold (DoubleJump, WallRun, WallCling) travel separately, so the
-- character can be seen doing a move before the claim for it is accepted.
-- `ClaimTiming.ClaimLagSeconds` bounds that gap, never a guessed slack: the descent curve runs that
-- much late, and an excess must outlast it before it's corrected. A confirmed
-- excess is snapped down with upward velocity killed. Zero tolerance
-- otherwise (ARCHITECTURE §9); measure with DebugFlags.VERTICAL_CEILING_DEBUG_LOGGING
-- before ever changing that.
local VerticalCeiling = {}

-- `timeToApex`: how long after this accept the move can still be rising
-- (see `verticalApexAt`).
function VerticalCeiling.Raise(session: PlayerSession, rise: number, timeToApex: number)
	session.verticalCeilingY += math.max(rise, 0)
	session.verticalApexAt = math.max(session.verticalApexAt, os.clock() + timeToApex)
	session.verticalRaisedAt = os.clock()
	session.verticalRaisedBy += math.max(rise, 0)
	if session.supported then
		local now = os.clock()
		local pending = session.groundRaise
		session.groundRaise = {
			rise = (if pending then pending.rise else 0) + math.max(rise, 0),
			apexAt = math.max(if pending then pending.apexAt else 0, now + timeToApex),
			at = now,
		}
	end
end

-- "Here, plus one jump": for a grounded, swimming, teleported or noclipping
-- character. A jump off a floor the server can vouch for also inherits the
-- floor's own upward speed (`floorRiseSpeed`, zero otherwise).
function VerticalCeiling.Anchor(
	session: PlayerSession,
	constants: EffectiveMovementConstants,
	now: number
)
	local launchSpeed = math.max(constants.JumpPower, session.groundLaunchSpeed or 0)
	-- A vault's mantle sets the feet just above the ledge and its launch leaves from
	-- there (see `vaultLaunchUntil`).
	if session.vaultLaunchUntil and now <= session.vaultLaunchUntil then
		launchSpeed = math.max(
			launchSpeed,
			TraversalMath.VaultMaxUpwardSpeed(
				constants.VaultUpwardSpeed,
				constants.VaultMaxMomentumUpward
			)
		)
	end
	local jumpSpeed = launchSpeed + session.floorRiseSpeed
	session.verticalCeilingY = session.rootPart.Position.Y
		+ TraversalMath.BallisticRise(jumpSpeed, Workspace.Gravity)
	session.verticalApexAt = now + TraversalMath.TimeToApex(jumpSpeed, Workspace.Gravity)
	session.verticalExcessSince = nil
	session.verticalAnchorY = session.rootPart.Position.Y
	session.verticalAnchorAt = now
	session.verticalRaisedAt = nil
	session.verticalRaisedBy = 0
	local pending = session.groundRaise
	if pending then
		if now - pending.at <= ClaimTiming.ClaimLagSeconds(session) then
			session.verticalCeilingY += pending.rise
			session.verticalApexAt = math.max(session.verticalApexAt, pending.apexAt)
			session.verticalRaisedAt = pending.at
			session.verticalRaisedBy = pending.rise
		else
			session.groundRaise = nil
		end
	end
end

function VerticalCeiling.Enforce(session: PlayerSession, constants: EffectiveMovementConstants)
	local rootPart = session.rootPart
	local character = session.humanoid.Parent :: Instance
	local y = rootPart.Position.Y
	local now = os.clock()
	local dt = now - session.verticalCheckAt
	session.verticalCheckAt = now
	local jumpRise = TraversalMath.BallisticRise(constants.JumpPower, Workspace.Gravity)
	local humanoidState = session.humanoid:GetState()

	-- Swimming in real terrain water re-anchors like ground does (designer
	-- answer 2026-09-24): the character can swim up to the surface and jump
	-- out. The water check is the server's own, so the label alone buys
	-- nothing outside water.
	local swimming = humanoidState == Enum.HumanoidStateType.Swimming
		and SpatialQueries.IsInWater(rootPart.Position)

	-- Touching real ground after a fast launch has topped out ends its flight:
	-- the allowance gets one landing grace (so the landing itself is judged
	-- at the launch's speed), then lapses even if the mirror never lands.
	if
		session.supported
		and session.airborneAllowedSpeed
		and not session.airborneAllowanceExpiresAt
		and now > session.verticalApexAt
	then
		session.airborneAllowanceExpiresAt = now + SpeedCaps.LANDING_MOMENTUM_GRACE_SECONDS
	end

	if DebugFlags.JUMP_LAUNCH_CAPTURE and RunService:IsStudio() then
		local capture = session.jumpCapture
		if session.supported or swimming then
			if capture and capture.peakY > capture.takeoffY then
				local peak = capture.peakY - capture.takeoffY
				print(
					string.format(
						"[JumpCapture] %s from=%s peak=%.2f toPeak=%.3fs launch=%.1f JumpPower=%.1f raisedBy=%.1f",
						session.player.Name,
						capture.from,
						peak,
						capture.peakAt - capture.takeoffAt,
						math.sqrt(2 * Workspace.Gravity * peak),
						constants.JumpPower,
						session.verticalRaisedBy
					)
				)
			end
			session.jumpCapture = nil
		elseif not capture then
			session.jumpCapture = {
				from = tostring(session.previousState),
				takeoffY = session.verticalAnchorY,
				takeoffAt = session.verticalAnchorAt,
				peakY = y,
				peakAt = now,
			}
		elseif y > capture.peakY then
			capture.peakY = y
			capture.peakAt = now
		end
	end

	if NoclipState.IsActive(session.player) or session.supported or swimming then
		VerticalCeiling.Anchor(session, constants, now)
		if swimming then
			-- Water ends a leap's flight the way landing does (re-audit N-001).
			session.airborneAllowedSpeed = nil
		end
		return
	end

	-- A wall the server's own probes confirm is holding the character up, so
	-- the descent clock waits: WallRun only sinks slowly and WallCling holds
	-- still, and both have server-enforced time limits.
	local current = session.fsm.current
	if current == MovementStates.WallRun or current == MovementStates.WallCling then
		session.verticalApexAt = math.max(session.verticalApexAt, now)
	end

	-- Climbing (ladders, trusses; designer answer 2026-09-24) on something the
	-- server confirms is a ladder (re-audit N-004): the ceiling rises at most
	-- at this player's own speed cap (the Humanoid climbs at a fraction of
	-- WalkSpeed, and the cap bounds WalkSpeed), and never more than one jump
	-- above where the character really is, so a climb can't bank height to
	-- spend later. The ladder holds the character up like a wall does.
	-- Grabbing one ends a leap's flight (N-001), so the allowance goes first
	-- and the climb rate is the ordinary cap.
	if
		humanoidState == Enum.HumanoidStateType.Climbing
		and SpatialQueries.QueryClimbable(rootPart, character)
	then
		session.airborneAllowedSpeed = nil
		local climbed = math.min(
			math.max(session.verticalCeilingY, y)
				+ SpeedCaps.EffectiveMaxSpeed(session, constants) * dt,
			y + jumpRise
		)
		session.verticalCeilingY = math.max(session.verticalCeilingY, climbed)
		session.verticalApexAt = math.max(session.verticalApexAt, now)
	end

	-- Unsupported from here on (support re-anchored above): the takeoff a
	-- pending SlideJump launch was waiting for has happened.
	session.groundLaunchSpeed = nil
	session.groundRaise = nil

	local lag = ClaimTiming.ClaimLagSeconds(session)
	local ceiling = TraversalMath.DescentCeiling(
		session.verticalCeilingY,
		session.verticalApexAt + lag,
		now,
		Workspace.Gravity
	)

	local excess = y - ceiling
	if excess <= 0 then
		session.verticalExcessSince = nil
		return
	end

	if not session.verticalExcessSince then
		session.verticalExcessSince = now
	end
	local excessFor = now - (session.verticalExcessSince :: number)

	if DebugFlags.VERTICAL_CEILING_DEBUG_LOGGING then
		print(
			string.format(
				"[VerticalCeiling] %s state=%s y=%.2f ceiling=%.2f apexY=%.2f pastApex=%.3fs excess=%.2f for=%.3fs lag=%.3fs supported=%s",
				session.player.Name,
				tostring(session.fsm.current),
				y,
				ceiling,
				session.verticalCeilingY,
				now - session.verticalApexAt,
				excess,
				excessFor,
				lag,
				tostring(session.supported)
			)
		)
	end

	if excessFor < lag then
		return
	end

	local raisedAt = session.verticalRaisedAt
	Violations.Report(session, "VerticalCeiling", {
		excess = excess,
		excessFor = excessFor,
		pastApex = now - session.verticalApexAt,
		lag = lag,
		vy = rootPart.AssemblyLinearVelocity.Y,
		aboveAnchor = y - session.verticalAnchorY,
		sinceAnchor = now - session.verticalAnchorAt,
		raisedBy = session.verticalRaisedBy,
		-- -1: nothing has raised the ceiling since the last anchor.
		sinceRaise = if raisedAt then now - raisedAt else -1,
	})

	-- Never below standing height on whatever lies between here and the
	-- target, so the snap can't bury the legs in a floor.
	local target = ceiling
	local floorY = SpatialQueries.QueryFloorBelow(
		rootPart,
		character,
		excess + MovementConstants.RigRootHeightAboveFeet
	)
	if floorY then
		target = math.max(target, floorY + MovementConstants.RigRootHeightAboveFeet)
	end

	local position = rootPart.Position
	rootPart.CFrame = (rootPart.CFrame - position) + Vector3.new(position.X, target, position.Z)
	local velocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, math.min(velocity.Y, 0), velocity.Z)
	session.verticalExcessSince = nil
	-- A flight that broke ballistics is no longer a leap (N-001).
	session.airborneAllowedSpeed = nil
end

-- The exemption hook for server-granted upward travel (audit M-001): lets
-- knockback, launch pads or Qinggong lift a player without tripping the
-- vertical ceiling, measured from wherever the player is right now. The
-- grant is treated as a launch that tops out `rise` higher, so the descent
-- check (re-audit N-002) waits as long as that launch would keep rising.
function VerticalCeiling.Grant(session: PlayerSession, rise: number)
	local granted = math.max(rise, 0)
	session.verticalCeilingY =
		math.max(session.verticalCeilingY, session.rootPart.Position.Y + granted)
	session.verticalApexAt = math.max(
		session.verticalApexAt,
		os.clock()
			+ TraversalMath.TimeToApex(
				math.sqrt(2 * Workspace.Gravity * granted),
				Workspace.Gravity
			)
	)
end

return VerticalCeiling
