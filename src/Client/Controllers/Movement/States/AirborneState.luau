--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local AirborneState = {}

AirborneState.CanEnter = StateRules.CanEnter[MovementStates.Airborne]

-- Landing target resolution (resolved 2026-09-13, docs/MOVEMENT.md §2;
-- extended 2026-09-14 §9 with the crouch branch) -- resolves straight to the
-- real grounded target based on currently held input, never through an
-- intermediate Idle frame. Deliberately never resolves to Run, even if
-- forward is held: jumping while running/sprinting is documented (§2) to drop
-- back down and reset the dwell timer on Exit, so landing must not let held
-- input silently re-grant Run without the double-tap gesture that's the only
-- real gate on that transition -- `CanEnter` alone doesn't encode "must have
-- double-tapped," only "grounded and has input," which Walk shares.
--
-- Extracted into its own function (TRAVERSAL-ROADMAP.md §4, Phase 1) so
-- DoubleJumpState can resolve the SAME landing decision for the rare "landed
-- mid-impulse" case, where handing off to Airborne first isn't legal
-- (Airborne.CanEnter requires `not grounded`, which already failed by the
-- time this needs to run) -- single source of truth, not a second copy of
-- the same crouch/hasInput branching.
function AirborneState.ResolveLandingTarget(context: ClientMovementContext): MovementStates.MovementState
	local hasInput = StateRules.HasMoveInput(context)
	if context.crouchHeld then
		return if hasInput then MovementStates.CrouchWalk else MovementStates.CrouchIdle
	elseif hasInput then
		return MovementStates.Walk
	end
	return MovementStates.Idle
end

function AirborneState.Enter(_context: ClientMovementContext) end

-- The decision lives in Update, not Exit: by the time Exit runs for the state
-- being left, RequestTransition has already committed to the next state
-- (StateMachine.luau fires `changed` after updating `current`), so Exit can
-- only ever be teardown, never the thing choosing where to land.
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		return
	end
	context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
