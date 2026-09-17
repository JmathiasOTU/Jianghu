--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local SpatialQueriesModule = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
type WallQueryResult = SpatialQueriesModule.WallQueryResult

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local WallLatchState = {}

WallLatchState.CanEnter = StateRules.CanEnter[MovementStates.WallLatch]

-- Frozen the instant the latch is entered -- Update re-derives X/Z + facing
-- from the latest wall query (drift correction on uneven walls) but never
-- touches this.
local frozenHeight: number? = nil

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
		+ flatNormal * context.constants.WallLatchSnapDistance
	local orientation = CFrame.new(Vector3.zero, -flatNormal)
	return target, orientation
end

function WallLatchState.Enter(context: ClientMovementContext)
	local query = context.wallQuery :: WallQueryResult
	frozenHeight = context.characterMover:GetPosition().Y
	context.characterMover:ClearVelocityOverride()
	local target, orientation = computeHold(context, query.position, query.normal, frozenHeight :: number)
	context.characterMover:SetPositionHold(target)
	context.characterMover:SetOrientationOverride(orientation)
end

function WallLatchState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	local query = context.wallQuery
	if not query then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local target, orientation = computeHold(context, query.position, query.normal, frozenHeight :: number)
	context.characterMover:SetPositionHold(target)
	context.characterMover:SetOrientationOverride(orientation)
end

function WallLatchState.Exit(context: ClientMovementContext)
	context.characterMover:ClearPositionHold()
	context.characterMover:ClearOrientationOverride()
	frozenHeight = nil
end

return WallLatchState
