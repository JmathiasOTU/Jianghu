--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)
local VerticalAllowanceGranted = require(script.Parent.Parent.Events.VerticalAllowanceGranted)
local MovementTuningState = require(script.Parent.Parent.State.MovementTuningState)
local Sessions = require(script.Sessions)
local Violations = require(script.Violations)
local Probes = require(script.Probes)
local SpeedCheck = require(script.SpeedCheck)
local VerticalCeiling = require(script.VerticalCeiling)
local Mirror = require(script.Mirror)
local TransitionBookkeeping = require(script.TransitionBookkeeping)
local TraversalClaims = require(script.TraversalClaims)
local TransitionClaims = require(script.TransitionClaims)
local DebugBroadcast = require(script.DebugBroadcast)

type MovementState = MovementStates.MovementState
type PlayerSession = Sessions.PlayerSession

-- Server-side movement validation (docs/MovementSystem.md §8): one
-- PlayerSession per character life, mirrored and checked every Heartbeat.
-- This module owns session lifecycle, remote wiring and the Heartbeat
-- order; each check lives in its own module alongside it.
local MovementValidationService = {}

-- Rate limit for RequestMovementTransition, independent of the FSM's own legality
-- check -- see docs/ARCHITECTURE.md §5 and Shared/Util/RateLimiter.luau. A
-- network-layer concern, not gameplay tuning, so it lives here rather than in
-- MovementConstants.
local TRANSITION_CLAIMS_PER_SECOND = 5

-- Level claims (crouch, audit M-006; camera lock, M-020): edges plus one 1/s
-- resync per level. A drop is self-healing since the client resends each
-- current level every second, so this only bounds spam, never correctness.
local LEVEL_CLAIMS_PER_SECOND = 6

-- Rate limit for ClaimTraversalMove, independent of RequestMovementTransition's
-- own limiter above (docs/MovementSystem.md §2) -- same reasoning, separate
-- counter so a burst against one event can never eat into the other's budget.
local TRAVERSAL_CLAIMS_PER_SECOND = 5

local function createSession(player: Player, humanoid: Humanoid, rootPart: BasePart): PlayerSession
	local trove = Trove.new()
	local fsm = trove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)
	local session: PlayerSession = {
		_trove = trove,
		player = player,
		humanoid = humanoid,
		rootPart = rootPart,
		fsm = fsm,
		rateLimiter = RateLimiter.new(TRANSITION_CLAIMS_PER_SECOND, 1),
		levelRateLimiter = RateLimiter.new(LEVEL_CLAIMS_PER_SECOND, 1),
		cameraLocked = false,
		runEnteredAt = nil,
		speedCheckPosition = rootPart.Position,
		speedCheckAt = os.clock(),
		speedBudget = 0,
		speedBudgetAt = os.clock(),
		previousCap = 0,
		supported = false,
		supportedSince = nil,
		floorSpeed = 0,
		floorRiseSpeed = 0,
		carrySpeed = 0,
		verticalCeilingY = rootPart.Position.Y + TraversalMath.BallisticRise(
			MovementTuningState.GetEffective(player).JumpPower,
			Workspace.Gravity
		),
		verticalApexAt = os.clock() + TraversalMath.TimeToApex(
			MovementTuningState.GetEffective(player).JumpPower,
			Workspace.Gravity
		),
		verticalAnchorY = rootPart.Position.Y,
		verticalAnchorAt = os.clock(),
		verticalRaisedAt = nil,
		verticalRaisedBy = 0,
		groundLaunchSpeed = nil,
		groundRaise = nil,
		jumpCapture = nil,
		verticalExcessSince = nil,
		verticalCheckAt = os.clock(),
		hardLandingLockPosition = nil,
		previousState = nil,
		lastTransitionAt = os.clock(),
		crouchHeld = false,
		doubleJumpUsed = false,
		doubleJumpLeftGround = false,
		crouchSuppressed = false,
		preAirborneLocomotion = nil,
		peakHeight = nil,
		hardLandingLockUntil = nil,
		traversalEntryAt = nil,
		traversalRateLimiter = RateLimiter.new(TRAVERSAL_CLAIMS_PER_SECOND, 1),
		slideGroundQuery = nil,
		slideGroundQueryAt = 0,
		wallRunQuery = nil,
		wallRunQueryAt = 0,
		wallRunEntryNormal = nil,
		wallRunEntryInstance = nil,
		airborneAllowedSpeed = nil,
		airborneAllowanceExpiresAt = nil,
		slideEntrySpeed = 0,
		pendingWallRunClaimUntil = nil,
		pendingWallLeapClaimUntil = nil,
		pendingSprintClaimUntil = nil,
		wallClingQuery = nil,
		wallClingQueryAt = 0,
		wallClingLockoutUntil = nil,
		wallClingBoostUsed = false,
		lastWallLeapWall = nil,
		wallLeapLeftGround = false,
		wallBoostStartedAt = nil,
		pendingWallClingClaimUntil = nil,
		wallClingEnteredAt = nil,
		pendingWallBoostClaimUntil = nil,
		pendingDoubleJumpClaimUntil = nil,
	}

	-- The speed window is deliberately NOT reset here (audit M-002): it used to
	-- be, to keep a window from straddling two tiers, but that let any client
	-- that could force transitions (by toggling its own Humanoid state) discard
	-- every window before it was ever measured. `SpeedCheck.Enforce` now builds
	-- each window's budget per Heartbeat from whichever cap was live, so a
	-- straddling window is judged correctly without throwing evidence away.
	trove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		TransitionBookkeeping.OnChanged(session, next, previous)
	end)

	-- Matches the client's own initial call in Movement/init.luau -- the FSM
	-- starts already in Idle, so no `changed` fires for it, and this session's
	-- CollisionGroup needs setting up front for the same reason.
	CollisionGroups.Apply(humanoid.Parent :: Model, MovementStates.Idle)
	trove:Add(CollisionGroups.Watch(humanoid.Parent :: Model))

	return session
end

-- The one teardown path for a session (audit M-011/M-023): death, character
-- removal, replacement, and leaving all end here, so the session's trove is
-- destroyed exactly once and the Heartbeat loop stops touching the old rig.
local function destroySession(player: Player)
	local session = Sessions.ByPlayer[player]
	if session then
		Sessions.ByPlayer[player] = nil
		session._trove:Destroy()
	end
end

-- Per-player connections (CharacterAdded/CharacterRemoving), outliving any
-- single character life -- destroyed on PlayerRemoving.
local playerTroves: { [Player]: Trove.Trove } = {}

local function onPlayerAdded(player: Player)
	local playerTrove = Trove.new()
	playerTroves[player] = playerTrove

	local function onCharacterAdded(character: Model)
		destroySession(player)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
		-- The waits above yield; a newer character (or a leave) may have
		-- arrived meanwhile, and this stale rig must not claim the session.
		if player.Character ~= character or playerTroves[player] ~= playerTrove then
			return
		end
		local session = createSession(player, humanoid, rootPart)
		Sessions.ByPlayer[player] = session
		-- Movement-only teardown, never a combat-defeat trigger (ARCHITECTURE
		-- §12): a dead rig stops being mirrored/validated/corrected.
		session._trove:Connect(humanoid.Died, function()
			if Sessions.ByPlayer[player] == session then
				destroySession(player)
			end
		end)
	end

	playerTrove:Connect(player.CharacterAdded, onCharacterAdded)
	playerTrove:Connect(player.CharacterRemoving, function(character: Model)
		local session = Sessions.ByPlayer[player]
		if session and session.humanoid.Parent == character then
			destroySession(player)
		end
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	destroySession(player)
	local playerTrove = playerTroves[player]
	if playerTrove then
		playerTroves[player] = nil
		playerTrove:Destroy()
	end
	Violations.ClearPlayer(player)
end

function MovementValidationService.Init()
	-- One-time workspace setup (docs/MovementSystem.md §4.2) -- collision group
	-- definitions replicate to every client automatically once registered
	-- here, so this never needs a client-side counterpart.
	CollisionGroups.RegisterGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Network.RequestMovementTransition.SetCallback(TransitionClaims.OnRequest)
	Network.ClaimTraversalMove.SetCallback(TraversalClaims.OnClaim)

	-- See DevToolsService's teleport handler: this is fired for any out-of-band
	-- character move (today, only the debug overlay's developer teleport) so
	-- SpeedCheck.Enforce doesn't measure the jump as an impossible speed and
	-- immediately snap the player back to where they were.
	CharacterTeleported:Connect(function(player: Player)
		local session = Sessions.ByPlayer[player]
		if session then
			SpeedCheck.ResetWindow(session)
			VerticalCeiling.Anchor(session, MovementTuningState.GetEffective(player), os.clock())
		end
	end)

	-- Server-granted upward travel (knockback, launch pads, Qinggong); see
	-- VerticalCeiling.Grant.
	VerticalAllowanceGranted:Connect(function(player: Player, rise: number)
		local session = Sessions.ByPlayer[player]
		if session then
			VerticalCeiling.Grant(session, rise)
		end
	end)

	-- Eight per-session checks run unconditionally for every player every
	-- Heartbeat -- each is already throttled internally (see e.g.
	-- SpeedCheckIntervalSeconds/SlideGroundRaycastThrottleSeconds/
	-- WallRunQueryThrottleSeconds/WallClingRecheckInterval), but staggering the
	-- OUTER loop itself (which players get checked which frame) is a real
	-- design decision, not a drive-by cleanup -- open scalability question for
	-- whenever a future traversal phase adds a ninth check here.
	--
	-- `Probes.UpdateSupport` runs first: every "is this character grounded" read in
	-- this Heartbeat (the wall probes, the mirror, the vertical ceiling) goes
	-- through `Probes.IsGrounded`, which needs this frame's support probe.
	-- `Probes.UpdateWallRunQuery`/`Probes.UpdateWallClingQuery` both run BEFORE
	-- `Mirror.PassiveTransitions` for the same same-frame-race reason
	-- `Probes.UpdatePeakHeight` already does (docs/MovementSystem.md §8.4): the sustain check inside
	-- `Mirror.PassiveTransitions` needs THIS frame's fresh probe, not last
	-- frame's. `TraversalClaims.RetryBuffered`/`TransitionClaims.RetryBufferedSprint` both
	-- run AFTER `Mirror.PassiveTransitions` for the identical reason -- a
	-- buffered retry needs to see THIS frame's mirrored state (e.g. a landing
	-- `Mirror.PassiveTransitions` just resolved), not last frame's. The vertical
	-- ceiling runs after every claim path, so a rise accepted this frame is
	-- already credited before it is measured.
	RunService.Heartbeat:Connect(function()
		for _, session in pairs(Sessions.ByPlayer) do
			local constants = MovementTuningState.GetEffective(session.player)
			Probes.UpdateSupport(session)
			Probes.UpdatePeakHeight(session)
			Probes.UpdateWallRunQuery(session)
			Probes.UpdateWallClingQuery(session)
			Mirror.PassiveTransitions(session)
			TraversalClaims.RetryBuffered(session)
			TransitionClaims.RetryBufferedSprint(session)
			Probes.UpdateSlideGroundQuery(session, constants)
			SpeedCheck.Enforce(session, constants)
			VerticalCeiling.Enforce(session, constants)
			DebugBroadcast.Send(session)
		end
	end)
end

return MovementValidationService
