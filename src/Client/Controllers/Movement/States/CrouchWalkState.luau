--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.Core.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Mirrors WalkState exactly (docs/MovementSystem.md §4.2) -- see CrouchIdleState for
-- the shared crouch-family reasoning (jump-block, ledge-fall-is-not-a-jump).
local CrouchWalkState = {}

CrouchWalkState.CanEnter = StateRules.CanEnter[MovementStates.CrouchWalk]

function CrouchWalkState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(context.constants.CrouchSpeed)
	context.characterMover:SetJumpBlocked(true)
end

function CrouchWalkState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif not context.crouchHeld then
		context.fsm:RequestTransition(
			if StateRules.HasMoveInput(context) then MovementStates.Walk else MovementStates.Idle,
			context
		)
	elseif not StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.CrouchIdle, context)
	end
end

function CrouchWalkState.Exit(context: ClientMovementContext)
	context.characterMover:SetJumpBlocked(false)
end

return CrouchWalkState
