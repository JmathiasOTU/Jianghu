--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Mirrors IdleState exactly (docs/MOVEMENT.md §9) -- same split against its
-- Walk-equivalent, same reasoning, just at CrouchSpeed instead of WalkSpeed.
local CrouchIdleState = {}

CrouchIdleState.CanEnter = StateRules.CanEnter[MovementStates.CrouchIdle]

function CrouchIdleState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(context.constants.CrouchSpeed)
	context.characterMover:SetJumpBlocked(true)
end

-- "Can't jump while crouched" (docs/MOVEMENT.md §9) blocks the jump INPUT
-- (via CharacterMover:SetJumpBlocked, set on Enter/cleared on Exit) -- it does
-- NOT make Airborne unreachable from here. A crouched player walking off a
-- ledge is involuntary ground loss, not the jump action, and must still fall
-- normally, so `not context.grounded` is unconditional below, exactly like
-- every other grounded state's landing check.
function CrouchIdleState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif not context.crouchHeld then
		context.fsm:RequestTransition(
			if StateRules.HasMoveInput(context) then MovementStates.Walk else MovementStates.Idle,
			context
		)
	elseif StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.CrouchWalk, context)
	end
end

function CrouchIdleState.Exit(context: ClientMovementContext)
	context.characterMover:SetJumpBlocked(false)
end

return CrouchIdleState
