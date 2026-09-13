--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local Network = require(script.Parent.Parent.Network.network)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

type PlayerSession = {
	humanoid: Humanoid,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	rateLimiter: RateLimiter.RateLimiter,
	runEnteredAt: number?,
}

-- Rate limit for RequestMovementTransition, independent of the FSM's own legality
-- check -- see docs/ARCHITECTURE.md §5 and Shared/Util/RateLimiter.luau. A
-- network-layer concern, not gameplay tuning, so it lives here rather than in
-- MovementConstants.
local TRANSITION_CLAIMS_PER_SECOND = 5

local MovementValidationService = {}

local sessions: { [Player]: PlayerSession } = {}

local function isGrounded(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
end

-- The server only ever validates legality (grounded / has-input / run-dwell), never
-- the client's raw WASD axes -- forward/backward/strafe are always false here since
-- nothing server-side reads them (only the client's SprintState uses them, to
-- decide its own local backpedal-drop; see docs/MOVEMENT.md §2 on why the mirror
-- doesn't need to replicate that exact cascade).
local function buildContext(session: PlayerSession): MovementContext
	local runDuration = if session.fsm.current == MovementStates.Run and session.runEnteredAt
		then os.clock() - (session.runEnteredAt :: number)
		else nil

	return {
		moveIntent = {
			direction = session.humanoid.MoveDirection,
			forward = false,
			backward = false,
			strafeLeft = false,
			strafeRight = false,
		},
		grounded = isGrounded(session.humanoid:GetState()),
		runDuration = runDuration,
	}
end

-- Idle/Walk/Airborne need no remote (Humanoid state already replicates), so the
-- mirror follows them passively here. Run/Sprint are only ever entered via the
-- explicit claim below -- this never attempts either, so an unclaimed client can
-- never end up mirrored as Run/Sprint no matter what MoveDirection says.
local function mirrorPassiveTransitions(session: PlayerSession)
	local context = buildContext(session)
	local current = session.fsm.current

	if current == MovementStates.Airborne then
		if context.grounded then
			local target = if StateRules.HasMoveInput(context) then MovementStates.Walk else MovementStates.Idle
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
	end
end

local function createSession(humanoid: Humanoid): PlayerSession
	return {
		humanoid = humanoid,
		fsm = StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter),
		rateLimiter = RateLimiter.new(TRANSITION_CLAIMS_PER_SECOND, 1),
		runEnteredAt = nil,
	}
end

local function onPlayerAdded(player: Player)
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		sessions[player] = createSession(humanoid)
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
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = buildContext(session)

	if session.fsm:RequestTransition(claimedState, context) and claimedState == MovementStates.Run then
		session.runEnteredAt = os.clock()
	end
end

function MovementValidationService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Network.RequestMovementTransition.SetCallback(onRequestMovementTransition)

	RunService.Heartbeat:Connect(function()
		for _, session in sessions do
			mirrorPassiveTransitions(session)
		end
	end)
end

return MovementValidationService
