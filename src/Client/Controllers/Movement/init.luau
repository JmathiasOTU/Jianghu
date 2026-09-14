--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local CharacterMover = require(script.CharacterMover)
local InputController = require(script.InputController)
local ClientMovementContextModule = require(script.ClientMovementContext)
local Network = require(script.Parent.Parent.Network.network)

local FacingController = require(script.Presentation.FacingController)
local LocomotionAnimator = require(script.Presentation.LocomotionAnimator)

local IdleState = require(script.States.IdleState)
local WalkState = require(script.States.WalkState)
local RunState = require(script.States.RunState)
local SprintState = require(script.States.SprintState)
local AirborneState = require(script.States.AirborneState)

type MovementState = MovementStates.MovementState
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- This folder syncs as a single ModuleScript via init.luau (not a flat
-- MovementController.luau) specifically so InputController/CharacterMover/States
-- can live as real children reachable via `script.X` -- ClientBootstrap's
-- Loader.LoadChildren(Controllers) only requires DIRECT children of Controllers,
-- never descendants, so anything placed flat under a `Controllers/Movement/`
-- subfolder without this init.luau trick would silently never get Init'd.
local MovementController = {}

local States = {
	[MovementStates.Idle] = IdleState,
	[MovementStates.Walk] = WalkState,
	[MovementStates.Run] = RunState,
	[MovementStates.Sprint] = SprintState,
	[MovementStates.Airborne] = AirborneState,
}

-- Only Run/Sprint are earned, exploit-relevant transitions that need a server
-- claim (see docs/MOVEMENT.md §5) -- Idle/Walk/Airborne need no remote.
local NETWORK_CLAIM_NAMES: { [MovementState]: "Run" | "Sprint" } = {
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
}

local input: InputController.InputController

local function setupCharacter(character: Model, lifeTrove: Trove.Trove)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local characterMover = lifeTrove:Add(CharacterMover.new(humanoid))
	local fsm = lifeTrove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)

	-- Presentation: purely cosmetic, never touched by states or the FSM (they only
	-- read it) -- docs/MOVEMENT.md §3/§4.
	lifeTrove:Add(FacingController.new(humanoid, rootPart))
	lifeTrove:Add(LocomotionAnimator.new(humanoid, rootPart, fsm, input))

	local function buildContext(): ClientMovementContext
		local runDuration = if fsm.current == MovementStates.Run
			then RunState.GetDuration()
			else nil
		return {
			moveIntent = input:GetMoveIntent(),
			grounded = characterMover:IsGrounded(),
			runDuration = runDuration,
			characterMover = characterMover,
			fsm = fsm,
		}
	end

	-- The FSM starts already in Idle, so no `changed` fires for it -- Enter has to
	-- run once up front to stay symmetric with every later transition.
	IdleState.Enter(buildContext())

	lifeTrove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		States[previous].Exit(buildContext())
		States[next].Enter(buildContext())

		local claimName = NETWORK_CLAIM_NAMES[next]
		if claimName then
			Network.RequestMovementTransition.Fire(claimName)
		end
	end)

	lifeTrove:Connect(input.RunRequested, function()
		fsm:RequestTransition(MovementStates.Run, buildContext())
	end)

	lifeTrove:Connect(RunService.Heartbeat, function(dt: number)
		States[fsm.current].Update(dt, buildContext())
	end)
end

function MovementController.Init()
	input = InputController.new()

	local player = Players.LocalPlayer
	local lifeTrove: Trove.Trove? = nil

	local function onCharacterAdded(character: Model)
		if lifeTrove then
			lifeTrove:Destroy()
		end
		lifeTrove = Trove.new()
		setupCharacter(character, lifeTrove)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		if lifeTrove then
			lifeTrove:Destroy()
			lifeTrove = nil
		end
	end)

	if player.Character then
		onCharacterAdded(player.Character)
	end
end

return MovementController
