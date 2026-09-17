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
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
