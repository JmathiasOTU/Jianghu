--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local SprintState = {}

SprintState.CanEnter = StateRules.CanEnter[MovementStates.Sprint]

function SprintState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(MovementConstants.SprintSpeed)
end

-- Sprint vs. strafing (resolved 2026-09-13, docs/MOVEMENT.md §2): tolerates
-- forward-diagonal input, drops back to Run on backpedal or pure strafe. Checked
-- separately from "no input at all" -> Idle (bug fixed 2026-09-13): Run.CanEnter
-- requires nonzero move input, so releasing every key and attempting
-- Sprint -> Run directly would fail CanEnter and leave the FSM stuck in Sprint --
-- attempting Idle first, before checking `forward`, avoids that dead end.
function SprintState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif not StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Idle, context)
	elseif not context.moveIntent.forward then
		context.fsm:RequestTransition(MovementStates.Run, context)
	end
end

function SprintState.Exit(_context: ClientMovementContext) end

return SprintState
