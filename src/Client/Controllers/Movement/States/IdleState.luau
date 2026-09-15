--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local IdleState = {}

IdleState.CanEnter = StateRules.CanEnter[MovementStates.Idle]

function IdleState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(context.constants.WalkSpeed)
end

-- Crouch is checked before the ordinary Walk check (docs/MOVEMENT.md §9) --
-- Ctrl takes priority the instant it's held. CrouchWalk is gated behind
-- CrouchIdle (only reachable from there or from Airborne on landing), so
-- holding Ctrl always lands in CrouchIdle first, even with W already held --
-- CrouchIdle's own Update immediately re-checks move input and advances to
-- CrouchWalk the very next tick if so.
function IdleState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif context.crouchHeld then
		context.fsm:RequestTransition(MovementStates.CrouchIdle, context)
	elseif StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Walk, context)
	end
end

function IdleState.Exit(_context: ClientMovementContext) end

return IdleState
