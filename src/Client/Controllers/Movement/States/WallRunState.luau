--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local WallRunState = {}

WallRunState.CanEnter = StateRules.CanEnter[MovementStates.WallRun]

-- Module-scope, not per-context -- same single-local-player-FSM pattern
-- RunState's dwell timer / SlideState's currentSpeed already establish.
local enteredAt: number? = nil

-- Only the horizontal axes are ever overridden (TRAVERSAL-ROADMAP.md §2) --
-- vertical stays entirely governed by gravity, same "disjoint axes"
-- HORIZONTAL_ONLY_FORCE idiom SlideState already established for its own
-- LinearVelocity override, just applied to a wall-tangent skim instead of a
-- ground-decay. No formula in the roadmap calls for a gravity-cancelling
-- hover here -- a wall run is a horizontal push along the surface for as
-- long as `WallRunMaxDurationSeconds` allows, still falling the whole time.
local HORIZONTAL_ONLY_FORCE = Vector3.new(math.huge, 0, math.huge)

function WallRunState.Enter(_context: ClientMovementContext)
	enteredAt = os.clock()
end

-- WallLatch is no longer tried automatically here -- its entry moved to a
-- jump-key press (Movement/init.luau), which tries WallLatch first whenever
-- the FSM isn't already latched, topology-gated to succeed only from
-- Airborne/WallRun.
function WallRunState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	local query = context.wallQuery
	local elapsed = os.clock() - (enteredAt :: number)
	if not query or elapsed >= context.constants.WallRunMaxDurationSeconds then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local facing = context.characterMover:GetFacingDirection()
	local tangent = TraversalMath.WallRunTangentVelocity(query.normal, facing, context.constants.WallRunSpeed)
	if tangent.Magnitude == 0 then
		-- Ran off the end of the wall's own tangent direction (e.g. facing
		-- swung to point straight into/out of it) -- nothing left to skim
		-- along, so this hands back to Airborne rather than holding zero
		-- horizontal velocity in place.
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	context.characterMover:SetVelocityOverride(tangent, HORIZONTAL_ONLY_FORCE)
end

function WallRunState.Exit(context: ClientMovementContext)
	context.characterMover:ClearVelocityOverride()
	enteredAt = nil
end

return WallRunState
