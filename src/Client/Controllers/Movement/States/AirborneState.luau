--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local AirborneState = {}

AirborneState.CanEnter = StateRules.CanEnter[MovementStates.Airborne]

function AirborneState.Enter(_context: ClientMovementContext) end

-- Landing (resolved 2026-09-13, docs/MOVEMENT.md §2): resolves straight to Walk or
-- Idle based on currently held input, never through an intermediate Idle frame.
-- Deliberately never attempts Run directly, even if forward is held: jumping while
-- running/sprinting is documented (§2) to drop back down and reset the dwell timer
-- on Exit, so landing must not let held input silently re-grant Run without the
-- double-tap gesture that's the only real gate on that transition -- CanEnter alone
-- doesn't encode "must have double-tapped," only "grounded and has input," which
-- Walk shares. The decision lives in Update, not Exit: by the time Exit runs for
-- the state being left, RequestTransition has already committed to the next state
-- (StateMachine.luau fires `changed` after updating `current`), so Exit can only
-- ever be teardown, never the thing choosing where to land.
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		return
	end
	if StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Walk, context)
	else
		context.fsm:RequestTransition(MovementStates.Idle, context)
	end
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
