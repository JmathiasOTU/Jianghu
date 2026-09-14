--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local ViolationTracker = require(ReplicatedStorage.Shared.Util.ViolationTracker)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

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
-- Forward/backward use MovementConstants.SprintForwardDeadzone rather than a bare
-- `> 0`/`< 0` zero-crossing (hardened 2026-09-13): real WASD input only ever
-- produces a facing/MoveDirection angle of 0/45/90+ degrees, so the deadzone (0.5,
-- comfortably below cos 45° ≈ 0.707) never affects legitimate diagonal Sprint-
-- holding -- it only closes off a spoofed `MoveDirection` sitting at a razor-thin
-- positive angle (e.g. 89°) that used to satisfy `> 0` and dodge the Sprint->Run
-- demotion while moving almost entirely sideways.
local function classifyMoveIntent(
	facing: Vector3,
	moveDirection: Vector3
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
	local deadzone = MovementConstants.SprintForwardDeadzone

	return forwardComponent > deadzone,
		forwardComponent < -deadzone,
		rightComponent < 0,
		rightComponent > 0
end

local function buildContext(session: PlayerSession): MovementContext
	local runDuration = if session.fsm.current == MovementStates.Run and session.runEnteredAt
		then os.clock() - (session.runEnteredAt :: number)
		else nil

	local moveDirection = session.humanoid.MoveDirection
	local facing = session.rootPart.CFrame.LookVector
	local forward, backward, strafeLeft, strafeRight = classifyMoveIntent(facing, moveDirection)

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
	fsm.changed:Connect(function()
		session.speedCheckPosition = rootPart.Position
		session.speedCheckAt = os.clock()
	end)

	return session
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
local function maxSpeedForState(state: MovementState): number
	if state == MovementStates.Run then
		return MovementConstants.RunSpeed
	elseif state == MovementStates.Sprint or state == MovementStates.Airborne then
		return MovementConstants.SprintSpeed
	end
	return MovementConstants.WalkSpeed
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
local function enforceSpeedSanity(session: PlayerSession)
	local now = os.clock()
	local elapsed = now - session.speedCheckAt
	if elapsed < MovementConstants.SpeedCheckIntervalSeconds then
		return
	end

	local position = session.rootPart.Position
	local previous = session.speedCheckPosition
	local flatDelta = Vector3.new(position.X - previous.X, 0, position.Z - previous.Z)
	local maxDistance = maxSpeedForState(session.fsm.current)
		* elapsed
		* MovementConstants.SpeedToleranceMultiplier

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
		speedViolations:Record(session.player)

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
local function broadcastDebugState(session: PlayerSession)
	if not DeveloperAllowlist.IsDeveloper(session.player) then
		return
	end

	local context = buildContext(session)
	local violation = speedViolations:Get(session.player)

	Network.MovementDebugState.Fire(session.player, {
		state = DEBUG_STATE_NAMES[session.fsm.current],
		runDuration = if context.runDuration then context.runDuration :: number else nil,
		violationCount = if violation then violation.count else 0,
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
			session.runEnteredAt = os.clock()
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
					(context.runDuration :: number) - MovementConstants.SprintThresholdSeconds
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
			enforceSpeedSanity(session)
			broadcastDebugState(session)
		end
	end)
end

return MovementValidationService
