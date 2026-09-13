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
-- forward-diagonal input, drops back to Run the moment the raw forward key is no
-- longer held -- covers backpedal, pure strafe, and fully releasing input alike,
-- since all three leave `forward` false. If input is fully zero, Run's own Update
-- demotes to Idle on the very next frame -- no special-casing needed here.
function SprintState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif not context.moveIntent.forward then
		context.fsm:RequestTransition(MovementStates.Run, context)
	end
end

function SprintState.Exit(_context: ClientMovementContext) end

return SprintState
