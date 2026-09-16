--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local SpatialQueriesModule = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
type WallQueryResult = SpatialQueriesModule.WallQueryResult

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local WallClimbState = {}

WallClimbState.CanEnter = StateRules.CanEnter[MovementStates.WallClimb]

-- Module-scope, not per-context -- same single-local-player-FSM pattern
-- SlideState's own currentSpeed/currentDirection already establish. The
-- height WallClimb is currently holding, grown/shrunk by held forward/
-- backward input every tick rather than fixed at Entry, so the player
-- actually climbs instead of just sticking in place at the entry height.
local holdHeight: number? = nil

-- Position/orientation hold target for the current tick (mechanic 5, §0's
-- AlignPosition+AlignOrientation decision): offset outward from the wall
-- surface along its own (flattened) normal by `WallClimbSnapDistance`, at
-- `height` -- re-derived from the LATEST wall query every tick (not fixed at
-- Entry) so climbing an uneven surface doesn't gradually drift the player
-- into or away from it. Orientation faces INTO the wall (`-flatNormal`).
local function computeHold(
	context: ClientMovementContext,
	wallPosition: Vector3,
	wallNormal: Vector3,
	height: number
): (Vector3, CFrame)
	local flatNormal = Vector3.new(wallNormal.X, 0, wallNormal.Z)
	if flatNormal.Magnitude > 0 then
		flatNormal = flatNormal.Unit
	end
	local target = Vector3.new(wallPosition.X, height, wallPosition.Z)
		+ flatNormal * context.constants.WallClimbSnapDistance
	local orientation = CFrame.new(Vector3.zero, -flatNormal)
	return target, orientation
end

function WallClimbState.Enter(context: ClientMovementContext)
	local query = context.wallQuery :: WallQueryResult
	holdHeight = context.characterMover:GetPosition().Y
	-- Silences the LinearVelocity override left over from a WallRun ->
	-- WallClimb upgrade (§4's own "WallClimb reachable from WallRun" edge) --
	-- position/orientation holds do the driving from here, same "every
	-- neighboring state that hands off sets up its own axes" principle
	-- SlideState's own Enter comment already documents for WalkSpeed.
	context.characterMover:ClearVelocityOverride()
	local target, orientation = computeHold(context, query.position, query.normal, holdHeight :: number)
	context.characterMover:SetPositionHold(target)
	context.characterMover:SetOrientationOverride(orientation)
end

-- Losing the wall entirely, topping out over a ledge, and climbing down onto
-- real ground are each their own branch, checked in that order, same
-- "specific-and-involuntary conditions before the steady-state tick" shape
-- SlideState.Update already uses (jump-off checked before its own decay).
function WallClimbState.Update(dt: number, context: ClientMovementContext)
	if context.grounded then
		-- Climbed down into real ground while still holding the wall --
		-- `Airborne.CanEnter` would reject re-entering Airborne here (already
		-- grounded), so this resolves the landing directly instead, same
		-- "mid-move landing" branch every other airborne-family state
		-- (DoubleJumpState, HardLandingState) already uses.
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	local query = context.wallQuery
	if not query then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if context.characterMover:IsLedgeAbove() then
		-- Topped out (mechanic 5, "wall at your feet, open air above"): a
		-- small forward-and-up nudge carries the player over the edge rather
		-- than leaving them pinned at the top -- Airborne's own gravity/
		-- landing resolution takes it from there, same hand-off every other
		-- mid-air-ending move already uses. Direct one-shot writes, not
		-- SetVelocityOverride -- Exit (called synchronously by this same
		-- RequestTransition) would otherwise clear a freshly-set constraint
		-- before the physics engine integrates it, same reasoning
		-- SetHorizontalVelocity/SetVerticalVelocity's own doc comments give.
		context.characterMover:SetHorizontalVelocity(-query.normal * context.constants.WallClimbSpeed)
		context.characterMover:SetVerticalVelocity(context.constants.WallClimbSpeed)
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local climbInput = (if context.moveIntent.forward then 1 else 0) - (if context.moveIntent.backward then 1 else 0)
	holdHeight = (holdHeight or query.position.Y) + climbInput * context.constants.WallClimbSpeed * dt

	local target, orientation = computeHold(context, query.position, query.normal, holdHeight :: number)
	context.characterMover:SetPositionHold(target)
	context.characterMover:SetOrientationOverride(orientation)
end

function WallClimbState.Exit(context: ClientMovementContext)
	context.characterMover:ClearPositionHold()
	context.characterMover:ClearOrientationOverride()
	holdHeight = nil
end

-- Climb-jump exit impulse (mechanic 5a, TRAVERSAL-ROADMAP.md §9) -- called
-- directly by the jump-input handler (Movement/init.luau), not through
-- RequestTransition's normal CanEnter path, since this needs to apply a real
-- launch impulse on the way out, not just pick a target state -- same "call
-- the state's own exported function" idiom AirborneState.ResolveLandingTarget
-- already establishes. Direct one-shot writes (not SetVelocityOverride) for
-- the same reason WallClimbState.Update's own top-out branch uses them: Exit
-- runs synchronously in the SAME call via RequestTransition below, before a
-- constraint-backed override would ever get a physics step to apply.
function WallClimbState.ClimbJump(context: ClientMovementContext)
	local query = context.wallQuery
	local pushDirection = if query then query.normal else Vector3.zero
	context.characterMover:SetHorizontalVelocity(pushDirection * context.constants.WallClimbJumpForce * 0.5)
	context.characterMover:SetVerticalVelocity(context.constants.WallClimbJumpForce)
	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

return WallClimbState
