--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local WalkState = {}

WalkState.CanEnter = StateRules.CanEnter[MovementStates.Walk]

function WalkState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(MovementConstants.WalkSpeed)
end

-- Run is deliberately never attempted here -- it's earned exclusively via
-- InputController's W double-tap detector (see docs/MOVEMENT.md §2), never as a
-- side effect of "input is currently held while walking."
function WalkState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif not StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Idle, context)
	end
end

function WalkState.Exit(_context: ClientMovementContext) end

return WalkState
