--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local IdleState = {}

IdleState.CanEnter = StateRules.CanEnter[MovementStates.Idle]

function IdleState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(MovementConstants.WalkSpeed)
end

function IdleState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Walk, context)
	end
end

function IdleState.Exit(_context: ClientMovementContext) end

return IdleState
