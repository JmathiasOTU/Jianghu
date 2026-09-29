--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local ClientMovementContextModule = require(script.Parent.Parent.Core.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- One-tick launch off a drop-off (docs/MovementSystem.md §4.10), the same
-- shape as SlideJumpState/WallLeapState: Enter adds the burst and hands back
-- to Airborne in the same synchronous call, so Update/Exit never run a real
-- frame. Requested by Movement/init.luau on the Airborne entry of a jump
-- takeoff from Run/Sprint or a slide jump; CanEnter judges it.
local LedgeJumpState = {}

LedgeJumpState.CanEnter = StateRules.CanEnter[MovementStates.LedgeJump]

-- One-shot horizontal write, not a velocity override: the synchronous hand-off
-- leaves no Exit to clear a constraint (SlideJumpState's reasoning). The
-- vertical speed the jump (or slide jump) gave is kept. `SetSpeed` targets
-- air control at the launched speed, as SlideJumpState does.
function LedgeJumpState.Enter(context: ClientMovementContext)
	local velocity = TraversalMath.LedgeJumpVelocity(
		context.characterMover:GetHorizontalVelocity(),
		context.constants.LedgeJumpBurstForce
	)
	context.characterMover:SetHorizontalVelocity(velocity)
	context.characterMover:SetSpeed(velocity.Magnitude)
	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

function LedgeJumpState.Update(_dt: number, _context: ClientMovementContext) end

function LedgeJumpState.Exit(_context: ClientMovementContext) end

return LedgeJumpState
