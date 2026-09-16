--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local LandingResolution = require(ReplicatedStorage.Shared.Movement.LandingResolution)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local AirborneState = {}

AirborneState.CanEnter = StateRules.CanEnter[MovementStates.Airborne]

-- Thin re-export of the shared landing-resolution logic (Shared/Movement/
-- LandingResolution.luau, unified there during the 2026-09-15 cleanup pass --
-- this used to be a full copy, hand-duplicated with the server's own
-- `resolveLandingTarget`). Kept under this name, not renamed, since
-- DoubleJumpState and HardLandingState both call `AirborneState.
-- ResolveLandingTarget` directly -- see LandingResolution.luau itself for the
-- full reasoning behind the branching.
AirborneState.ResolveLandingTarget = LandingResolution.Resolve

function AirborneState.Enter(_context: ClientMovementContext) end

-- The decision lives in Update, not Exit: by the time Exit runs for the state
-- being left, RequestTransition has already committed to the next state
-- (StateMachine.luau fires `changed` after updating `current`), so Exit can
-- only ever be teardown, never the thing choosing where to land.
--
-- WallClimb is tried before WallRun (TRAVERSAL-ROADMAP.md §4/§9 mechanic
-- 4/5): its own CanEnter (Shared/Movement/StateRules.luau) is the stricter,
-- more deliberate gesture ("pressing INTO the wall"), so it has to win the
-- race whenever both would otherwise be legal for the same wall/input frame
-- -- WallRun's own CanEnter has no equivalent exclusion, it just never gets
-- asked once Climb's RequestTransition already succeeded. Both calls are
-- harmless no-ops when their own CanEnter isn't satisfied, same "topology
-- alone gates it" reasoning DoubleJump's unconditional JumpRequested trigger
-- already relies on -- neither needs its own separate "is this even
-- possible" pre-check duplicated here.
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	if context.fsm:RequestTransition(MovementStates.WallClimb, context) then
		return
	end
	if context.fsm:RequestTransition(MovementStates.WallRun, context) then
		return
	end
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
