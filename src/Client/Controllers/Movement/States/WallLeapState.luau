--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- One synchronous frame, same shape as SlideJumpState: Enter applies the
-- launch impulse and hands off to Airborne in the same call, so Update/Exit
-- never actually run for a real frame.
local WallLeapState = {}

WallLeapState.CanEnter = StateRules.CanEnter[MovementStates.WallLeap]

function WallLeapState.Enter(context: ClientMovementContext)
	local query = context.wallQuery
	local pushDirection = if query then query.normal else Vector3.zero
	context.characterMover:SetHorizontalVelocity(pushDirection * context.constants.WallLeapForce * 0.5)
	context.characterMover:SetVerticalVelocity(context.constants.WallLeapForce)
	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

function WallLeapState.Update(_dt: number, _context: ClientMovementContext) end

function WallLeapState.Exit(_context: ClientMovementContext) end

return WallLeapState
