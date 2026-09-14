--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local ViolationTracker = require(ReplicatedStorage.Shared.Util.ViolationTracker)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)
local MovementTuningState = require(script.Parent.Parent.State.MovementTuningState)
local NoclipState = require(script.Parent.Parent.State.NoclipState)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants

-- Symbol -> the plain string literal Network.MovementDebugState's payload needs
-- (Zap enums are string unions, not Symbols) -- same lookup-table shape as
-- init.luau's NETWORK_CLAIM_NAMES, so a typo here fails to compile rather than
-- silently sending "Unknown" forever.
local DEBUG_STATE_NAMES: { [MovementState]: Network.DebugMovementState } = {
	[MovementStates.Idle] = "Idle",
	[MovementStates.Walk] = "Walk",
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
	[MovementStates.Airborne] = "Airborne",
}

type PlayerSession = {
	player: Player,
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	rateLimiter: RateLimiter.RateLimiter,
	runEnteredAt: number?,
	speedCheckPosition: Vector3,
	speedCheckAt: number,
	-- Landing-momentum grace (docs/MOVEMENT.md §5, added 2026-09-14): the state
	-- this session was in immediately before its most recent transition, and
	-- when that transition happened -- generic over which transition, never
	-- keyed to "landed from Airborne" specifically. See `effectiveMaxSpeed`.
	previousState: MovementState?,
	lastTransitionAt: number,
}

-- Rate limit for RequestMovementTransition, independent of the FSM's own legality
-- check -- see docs/ARCHITECTURE.md §5 and Shared/Util/RateLimiter.luau. A
-- network-layer concern, not gameplay tuning, so it lives here rather than in
-- MovementConstants.
local TRANSITION_CLAIMS_PER_SECOND = 5

-- Temporary instrumentation for the 2026-09-13 Sprint-rubber-banding
-- investigation (docs/MOVEMENT.md §5) -- prints real numbers instead of guessing
-- at a tolerance. Flip on for a playtest, off for normal play; left in (not
-- deleted) since Stage 2's WallRun/etc. validation will want the same kind of
-- capture again.
local SPEED_SANITY_DEBUG_LOGGING = false

-- Sized from a real 2026-09-14 playtest capture (docs/MOVEMENT.md §5), not a
-- guess: every landing sample showed the FIRST `enforceSpeedSanity` check after
-- an Airborne->Walk transition firing at elapsed ~0.50-0.517s (just the normal
-- check cadence) and never a second correction after it -- the whole residual-
-- momentum transient decays back under the new cap within that first window,
-- it just needs grace that actually covers it. One `SpeedCheckIntervalSeconds`
-- of grace (the original placeholder) was already expired BY the time that
-- first check ran (elapsed >= grace), which is why it measured zero
-- protection. Two intervals comfortably covers the observed ~0.5-0.517s first
-- check with margin, without over-granting a second window nothing in the
-- capture ever showed a need for.
local LANDING_MOMENTUM_GRACE_SECONDS = 2 * MovementConstants.SpeedCheckIntervalSeconds

local MovementValidationService = {}

local sessions: { [Player]: PlayerSession } = {}
local speedViolations = ViolationTracker.new()

local function isGrounded(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
end

-- The server never sees raw WASD key state (that's client-only), so it can't
-- literally reconstruct "is W held" the way InputController does. Instead this
-- mirrors the same forward/backward/strafe *classification* SprintState.Update
-- relies on, geometrically: forward/backward from facing's dot with MoveDirection
-- past a deadzone, strafeLeft/strafeRight from the sign of the analogous cross
-- product (same convention as LocomotionAnimator.resolveDirectionBucket -- positive
-- means Right). Both inputs (rootPart.CFrame, humanoid.MoveDirection) are
-- server-trusted replicated state, not anything the client asserts directly, which
-- is what makes this a real fix rather than trusting the client's own claim (see
-- docs/MOVEMENT.md §5).
--
-- Forward/backward use a deadzone (this session's effective
-- SprintForwardDeadzone, docs/MOVEMENT.md §8 -- MovementConstants' shipped
-- 0.5 unless a developer is live-tuning it) rather than a bare `> 0`/`< 0`
-- zero-crossing (hardened 2026-09-13): real WASD input only ever produces a
-- facing/MoveDirection angle of 0/45/90+ degrees, so the shipped deadzone
-- (comfortably below cos 45° ≈ 0.707) never affects legitimate diagonal
-- Sprint-holding -- it only closes off a spoofed `MoveDirection` sitting at a
-- razor-thin positive angle (e.g. 89°) that used to satisfy `> 0` and dodge
-- the Sprint->Run demotion while moving almost entirely sideways.
local function classifyMoveIntent(
	facing: Vector3,
	moveDirection: Vector3,
	deadzone: number
): (boolean, boolean, boolean, boolean)
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	local flatMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flatFacing.Magnitude == 0 or flatMove.Magnitude == 0 then
		return false, false, false, false
	end
	flatFacing = flatFacing.Unit
	flatMove = flatMove.Unit

	local forwardComponent = flatFacing:Dot(flatMove)
	local rightComponent = flatMove:Cross(flatFacing).Y

	return forwardComponent > deadzone,
		forwardComponent < -deadzone,
		rightComponent < 0,
		rightComponent > 0
end

-- `constants` is this session's EFFECTIVE tuning (docs/MOVEMENT.md §8) --
-- read fresh from MovementTuningState on every call rather than cached on the
-- session, so a live override change is picked up on the very next Heartbeat
-- with no extra invalidation bookkeeping. StateRules.CanEnter (shared with the
-- client) reads SprintThresholdSeconds off this same field, never off
-- MovementConstants directly, so the two can never disagree about the number
-- actually in effect for this player.
local function buildContext(session: PlayerSession): MovementContext
	local constants = MovementTuningState.GetEffective(session.player)

	local runDuration = if session.fsm.current == MovementStates.Run and session.runEnteredAt
		then os.clock() - (session.runEnteredAt :: number)
		else nil

	local moveDirection = session.humanoid.MoveDirection
	local facing = session.rootPart.CFrame.LookVector
	local forward, backward, strafeLeft, strafeRight =
		classifyMoveIntent(facing, moveDirection, constants.SprintForwardDeadzone)

	return {
		moveIntent = {
			direction = moveDirection,
			forward = forward,
			backward = backward,
			strafeLeft = strafeLeft,
			strafeRight = strafeRight,
		},
		grounded = isGrounded(session.humanoid:GetState()),
		runDuration = runDuration,
		constants = constants,
	}
end

-- Idle/Walk/Airborne need no remote (Humanoid state already replicates), so the
-- mirror follows them passively here. Run/Sprint are only ever *entered* via the
-- explicit claim below -- this never attempts either as a target, so an unclaimed
-- client can never end up mirrored as Run/Sprint no matter what MoveDirection says.
-- Sprint's demotion back to Run IS handled here, on the server's own initiative
-- (see docs/MOVEMENT.md §5) -- it doesn't wait for the client to re-claim Run.
local function mirrorPassiveTransitions(session: PlayerSession)
	local context = buildContext(session)
	local current = session.fsm.current

	if current == MovementStates.Airborne then
		if context.grounded then
			local target = if StateRules.HasMoveInput(context)
				then MovementStates.Walk
				else MovementStates.Idle
			session.fsm:RequestTransition(target, context)
		end
		return
	end

	if not context.grounded then
		session.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if current == MovementStates.Idle then
		if StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.Walk, context)
		end
	elseif not StateRules.HasMoveInput(context) then
		-- Walk, Run, or Sprint with no input left: drop straight to Idle.
		session.fsm:RequestTransition(MovementStates.Idle, context)
	elseif
		current == MovementStates.Sprint
		and not session.humanoid.AutoRotate
		and not context.moveIntent.forward
	then
		-- Same demotion condition as SprintState.Update client-side (backpedal or
		-- pure strafe drops Sprint), enforced independently of whether a modified
		-- client ever sends the matching reclaim.
		--
		-- Gated on `not session.humanoid.AutoRotate` (found during the 2026-09-13
		-- rubber-banding investigation): `classifyMoveIntent` approximates "is this
		-- forward" from `rootPart.CFrame.LookVector` vs. `MoveDirection`, but
		-- `FacingController`'s own fix (§4, also 2026-09-13) established that
		-- facing *deliberately* lags MoveDirection whenever `AutoRotate` is true
		-- (unlocked camera) -- Roblox's own ground controller turns the character
		-- to catch up rather than snapping. A player who simply looks around while
		-- holding forward, unlocked, can swing MoveDirection well ahead of facing
		-- for a few frames -- comfortably past this check's deadzone -- with zero
		-- backward/strafe input at all. That's not a desync to correct for, it's
		-- this proxy being the wrong signal in that mode: strafe-style facing
		-- decoupling (and with it, a meaningful "backpedal relative to facing")
		-- only applies while locked in the first place (see this doc's intro).
		-- `AutoRotate` itself is a plain replicated Humanoid property the
		-- server already trusts elsewhere (`CharacterMover`/`FacingController`
		-- toggle it, same as `WalkSpeed`), so this costs no new trust assumption.
		--
		-- This narrows, rather than removes, server enforcement while unlocked:
		-- the "no input at all -> Idle" branch above and `enforceSpeedSanity`'s
		-- speed cap both still apply unconditionally. The one residual gap is
		-- narrow and low-severity -- a modified client could hold Sprint's speed
		-- cap (not Run's) while moving backward, unlocked, without ever
		-- backpedal-demoting -- documented in docs/MOVEMENT.md §5 rather than
		-- silently accepted.
		if session.fsm:RequestTransition(MovementStates.Run, context) then
			-- RunState.Enter resets the client's own dwell clock on every entry
			-- into Run, this demotion included -- without this reset, a client
			-- that never re-sends the "Run" claim (bug found 2026-09-13: a
			-- malicious one has no reason to) would keep the ORIGINAL
			-- runEnteredAt from before Sprint, so re-claiming "Sprint" a moment
			-- later would instantly pass the dwell check off stale elapsed time,
			-- instead of requiring a fresh 3-second Run streak like a legitimate
			-- client always does.
			session.runEnteredAt = os.clock()
		end
	end
end

-- WalkSpeed is the ground-truth cap Roblox's own Humanoid:Move() enforces for a
-- well-behaved client, but WalkSpeed itself is just a replicated property the
-- network-owning client (the player, for their own character) can set directly --
-- a classic speed-hack bypasses the FSM entirely and never calls
-- RequestMovementTransition at all, it just writes a bigger WalkSpeed straight onto
-- the Humanoid. So the cap checked here is keyed off the SERVER's own mirrored FSM
-- state, never `humanoid.WalkSpeed` as reported -- that value can't be trusted at
-- all (docs/ARCHITECTURE.md §3). Airborne has no state of its own that sets speed
-- (`AirborneState.Enter` is a no-op, per `AirborneState.luau`) -- whatever tier was
-- active at takeoff carries into the jump -- so it's capped at the ceiling
-- (SprintSpeed) rather than guessing which tier the player jumped from.
local function maxSpeedForState(state: MovementState, constants: EffectiveMovementConstants): number
	if state == MovementStates.Run then
		return constants.RunSpeed
	elseif state == MovementStates.Sprint or state == MovementStates.Airborne then
		return constants.SprintSpeed
	end
	return constants.WalkSpeed
end

-- Landing-momentum grace (docs/MOVEMENT.md §5, added 2026-09-14): distinct from
-- `createSession`'s existing per-transition baseline reset below, which only
-- ever fixed windows that straddled a transition boundary (mixing old- and
-- new-tier motion in one sample). This fixes a DIFFERENT case -- a window
-- entirely AFTER a transition, already in the new state, still measuring real
-- residual momentum: Humanoid's ground controller decelerates toward a lower
-- WalkSpeed target over a real, documented handful of frames rather than
-- snapping instantly, and that tail can genuinely exceed the new tier's cap for
-- a moment (most sharply landing from Sprint/Airborne down into Walk).
--
-- Keyed generically off "the cap decreased at the last transition," never off
-- "coming from Airborne" or "going to Walk" specifically -- `session.previousState`
-- is whatever state was active immediately before, so Stage 2's WallRun/
-- ClimbVault/LedgeGrab/Slide (all of which will exit into Airborne or Walk with
-- their own residual momentum) get this grace for free the moment their own cap
-- is taught to `maxSpeedForState`, with no separate copy of this fix needed.
local function effectiveMaxSpeed(session: PlayerSession, constants: EffectiveMovementConstants): number
	local currentCap = maxSpeedForState(session.fsm.current, constants)
	local previousState = session.previousState
	if not previousState then
		return currentCap
	end

	local previousCap = maxSpeedForState(previousState, constants)
	if previousCap <= currentCap then
		-- The cap went up or stayed the same -- there's no residual-momentum
		-- tail to grace here, only ever downward transitions produce one.
		return currentCap
	end

	if os.clock() - session.lastTransitionAt < LANDING_MOMENTUM_GRACE_SECONDS then
		return previousCap
	end
	return currentCap
end

local function createSession(player: Player, humanoid: Humanoid, rootPart: BasePart): PlayerSession
	local fsm = StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	local session: PlayerSession = {
		player = player,
		humanoid = humanoid,
		rootPart = rootPart,
		fsm = fsm,
		rateLimiter = RateLimiter.new(TRANSITION_CLAIMS_PER_SECOND, 1),
		runEnteredAt = nil,
		speedCheckPosition = rootPart.Position,
		speedCheckAt = os.clock(),
		previousState = nil,
		lastTransitionAt = os.clock(),
	}

	-- Reset the speed-sanity baseline on EVERY FSM transition, not just Sprint
	-- entry (found during the 2026-09-13 rubber-banding investigation): any
	-- transition can change `maxSpeedForState`'s cap, and Humanoid's WalkSpeed
	-- changes are not instant -- its ground controller accelerates/decelerates
	-- toward the new target over a real, documented handful of frames, it doesn't
	-- snap velocity immediately (docs/ARCHITECTURE.md §9's own example of an
	-- acceptable tolerance is exactly this class of thing). A window that
	-- straddles a transition boundary would compare a mix of old- and new-tier
	-- motion against only the new tier's cap -- most sharply on a large drop
	-- (Sprint/Airborne -> Walk on landing), where residual momentum can still
	-- exceed the new, much lower cap for a moment. Starting the window fresh at
	-- the boundary sidesteps needing to quantify that transient's length at all,
	-- rather than padding `SpeedToleranceMultiplier` to guess-cover it.
	fsm.changed:Connect(function(next: MovementState, previous: MovementState)
		local now = os.clock()
		session.speedCheckPosition = rootPart.Position
		session.speedCheckAt = now

		-- Landing-momentum grace bookkeeping (see `effectiveMaxSpeed` below) --
		-- just records what state this session was in and when, regardless of
		-- which states are involved; `effectiveMaxSpeed` is what decides whether
		-- that's actually a cap decrease worth gracing.
		session.previousState = previous
		session.lastTransitionAt = now

		if SPEED_SANITY_DEBUG_LOGGING then
			local constants = MovementTuningState.GetEffective(player)
			local previousCap = maxSpeedForState(previous, constants)
			local newCap = maxSpeedForState(next, constants)
			if previousCap > newCap then
				print(
					string.format(
						"[SpeedSanity] %s %s -> %s, cap %.1f -> %.1f, grace window started",
						player.Name,
						tostring(previous),
						tostring(next),
						previousCap,
						newCap
					)
				)
			end
		end
	end)

	return session
end

-- Lightweight anti-noclip/speed-hack net (docs/MOVEMENT.md §5): not a full
-- predict-validate-correct loop (no raycasts, no world geometry) -- Phase 1 has
-- nothing spatial to validate yet, just "did this player cover more ground than
-- their currently-mirrored tier allows." Sampled over a fixed interval rather than
-- every Heartbeat: per-frame `CFrame` replication from an owning client arrives in
-- bursts, not evenly, so a raw frame-to-frame delta would false-positive on normal
-- replication jitter long before it caught a real speed hack. Vertical (Y) motion
-- is deliberately excluded -- falling/jumping isn't gated by any WalkSpeed tier,
-- and this check has no business policing gravity.
--
-- Exempted entirely while `NoclipState.IsActive` (docs/MOVEMENT.md §8) -- the
-- scouting tool's whole point is to move faster than any tier's cap allows, so
-- without this exemption it would rubber-band the very thing it exists for.
-- Checked against the SERVER's own authorized record, never a client-reported
-- flag (docs/ARCHITECTURE.md §3) -- DevToolsService.luau is the only writer.
local function enforceSpeedSanity(session: PlayerSession, constants: EffectiveMovementConstants)
	if NoclipState.IsActive(session.player) then
		return
	end

	local now = os.clock()
	local elapsed = now - session.speedCheckAt
	if elapsed < MovementConstants.SpeedCheckIntervalSeconds then
		return
	end

	local position = session.rootPart.Position
	local previous = session.speedCheckPosition
	local flatDelta = Vector3.new(position.X - previous.X, 0, position.Z - previous.Z)
	local maxDistance = effectiveMaxSpeed(session, constants) * elapsed * constants.SpeedToleranceMultiplier

	if flatDelta.Magnitude > maxDistance then
		-- Unconditional (not gated behind SPEED_SANITY_DEBUG_LOGGING below): every
		-- correction is worth seeing in the console as it happens, not just during
		-- an opt-in debug session.
		print(
			string.format(
				"[SpeedSanity] %s state=%s flatDelta=%.2f maxDistance=%.2f elapsed=%.3f",
				session.player.Name,
				tostring(session.fsm.current),
				flatDelta.Magnitude,
				maxDistance,
				elapsed
			)
		)
		-- The detail captured here (docs/MOVEMENT.md §8) is exactly the same
		-- flatDelta/maxDistance/elapsed data the print above already has --
		-- ViolationTracker keeps a bounded history of it instead of only the
		-- running count, so broadcastDebugState can show the overlay's last
		-- few corrections, not just how many there have been.
		speedViolations:Record(session.player, {
			flatDelta = flatDelta.Magnitude,
			maxDistance = maxDistance,
			elapsed = elapsed,
		})

		local corrected = Vector3.new(previous.X, position.Y, previous.Z)
		session.rootPart.CFrame = (session.rootPart.CFrame - position) + corrected
		position = corrected
	end

	session.speedCheckPosition = position
	session.speedCheckAt = now
end

-- Debug overlay (F4, developer-only, docs/MOVEMENT.md): one-way broadcast of this
-- session's mirrored state to the owning client only, so the overlay can flag
-- client/server disagreement instead of only showing the client's own
-- (self-reported) view -- that's the actual point of the panel. Restricted to
-- developers so a normal player's client never even receives this traffic.
--
-- `violations` (docs/MOVEMENT.md §8) sends ViolationTracker's bounded history,
-- not just the running count -- `ageSeconds` is computed fresh right here,
-- every broadcast, from this server's own `os.clock()` rather than sending
-- the raw recorded timestamp, since the two machines' clocks aren't
-- comparable (unlike `elapsed`, which is already a duration, not a moment).
local function broadcastDebugState(session: PlayerSession)
	if not DeveloperAllowlist.IsDeveloper(session.player) then
		return
	end

	local context = buildContext(session)
	local violation = speedViolations:Get(session.player)
	local now = os.clock()

	local violationEntries: { { flatDelta: number, maxDistance: number, elapsed: number, ageSeconds: number } } =
		{}
	if violation then
		for _, entry in violation.history do
			table.insert(violationEntries, {
				flatDelta = entry.flatDelta,
				maxDistance = entry.maxDistance,
				elapsed = entry.elapsed,
				ageSeconds = now - entry.at,
			})
		end
	end

	Network.MovementDebugState.Fire(session.player, {
		state = DEBUG_STATE_NAMES[session.fsm.current],
		runDuration = if context.runDuration then context.runDuration :: number else nil,
		violationCount = if violation then violation.count else 0,
		violations = violationEntries,
	})
end

local function onPlayerAdded(player: Player)
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
		sessions[player] = createSession(player, humanoid, rootPart)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session then
		session.fsm:Destroy()
	end
	sessions[player] = nil
	speedViolations:Clear(player)
end

-- The real exploit surface (see docs/ARCHITECTURE.md §5): a modified client could
-- claim Sprint without ever earning it. Legality is checked against this session's
-- OWN runEnteredAt timestamp -- never anything the client sends -- same
-- lag-compensation principle as parry (§4), applied to a locomotion transition.
local function onRequestMovementTransition(player: Player, claim: "Run" | "Sprint")
	local session = sessions[player]
	if not session then
		return
	end

	if not session.rateLimiter:tryAcquire() then
		if SPEED_SANITY_DEBUG_LOGGING then
			-- Confirms/rules out the rate limiter itself as a cause of dropped
			-- legitimate claims (docs/MOVEMENT.md §5) -- 5/second should never be
			-- reachable by normal play (one claim per Run/Sprint entry), so this
			-- firing during an ordinary playtest would point at the limiter, not
			-- at enforceSpeedSanity, as the actual bug.
			print(string.format("[SpeedSanity] %s RATE LIMITED claim=%s", player.Name, claim))
		end
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = buildContext(session)

	if session.fsm:RequestTransition(claimedState, context) then
		if claimedState == MovementStates.Run then
			-- Backdated by half this player's measured RTT (docs/MOVEMENT.md §5,
			-- fixed 2026-09-14) -- the claim carrying this instant already reached
			-- the server late, so stamping raw receipt time skews the server's
			-- dwell clock later than the client's own, which used to land a
			-- legitimate first Sprint claim right on the 3s boundary (near-even
			-- odds of rejection from jitter alone) instead of comfortably past it.
			local ping = player:GetNetworkPing()
			-- Guards `GetNetworkPing()` returning 0 (no sample yet -- e.g. this is
			-- the very first claim right after spawn) or an implausibly large
			-- reading: capped at half of `SprintThresholdSeconds` so a bad reading
			-- here can never backdate far enough to let Sprint be claimed with
			-- little to no real Run dwell.
			local backdateSeconds = if ping > 0
				then math.min(ping / 2, context.constants.SprintThresholdSeconds / 2)
				else 0
			session.runEnteredAt = os.clock() - backdateSeconds
		elseif SPEED_SANITY_DEBUG_LOGGING and context.runDuration then
			-- The server only ever sees "Sprint" claimed once its OWN runEnteredAt
			-- says the dwell is satisfied, so this is never negative -- it's purely
			-- how much the client's local dwell clock (which crossed the 3s
			-- threshold first, then had to round-trip this claim over the network)
			-- had already run past 3s by the time the server processed it. A
			-- consistently large number here is the claim-round-trip lag docs/
			-- MOVEMENT.md §5 asks to rule in or out as a rubber-banding cause.
			print(
				string.format(
					"[SpeedSanity] %s Sprint claim accepted, dwell overshoot=%.3fs",
					player.Name,
					(context.runDuration :: number) - context.constants.SprintThresholdSeconds
				)
			)
		end
	end
end

function MovementValidationService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Network.RequestMovementTransition.SetCallback(onRequestMovementTransition)

	-- See DevToolsService's teleport handler: this is fired for any out-of-band
	-- character move (today, only the debug overlay's developer teleport) so
	-- enforceSpeedSanity doesn't measure the jump as an impossible speed and
	-- immediately snap the player back to where they were.
	CharacterTeleported:Connect(function(player: Player)
		local session = sessions[player]
		if session then
			session.speedCheckPosition = session.rootPart.Position
			session.speedCheckAt = os.clock()
		end
	end)

	RunService.Heartbeat:Connect(function()
		for _, session in sessions do
			mirrorPassiveTransitions(session)
			enforceSpeedSanity(session, MovementTuningState.GetEffective(session.player))
			broadcastDebugState(session)
		end
	end)
end

return MovementValidationService
