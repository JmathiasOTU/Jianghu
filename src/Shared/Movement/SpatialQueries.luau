--!strict
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

-- Pure geometry reads (TRAVERSAL-ROADMAP.md §3) -- called identically by
-- client prediction (via `CharacterMover:QueryGround`) and server
-- resimulation (`MovementValidationService`), so both sides can only ever
-- agree or disagree about the SAME raycast, never two independently
-- hand-synced copies of "how do we detect the ground." No stored state of
-- its own -- nothing here needs a Trove or a cleanup path.
local SpatialQueries = {}

local UP = Vector3.new(0, 1, 0)

export type GroundQueryResult = {
	position: Vector3,
	normal: Vector3,
}

export type WallQueryResult = {
	position: Vector3,
	normal: Vector3,
}

-- Slide's own ground-normal read (mechanic 3a) -- only ever called while
-- already grounded (Slide's `CanEnter`/`Update` both require
-- `context.grounded`), so this is purely a surface-normal probe, not an
-- existence check. `filterInstance` excludes the caster's own character
-- (client: `humanoid.Parent`, server: `session.humanoid.Parent`) so the cast
-- never hits its own limbs.
function SpatialQueries.QueryGround(
	rootPart: BasePart,
	filterInstance: Instance,
	castDistance: number?
): GroundQueryResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { filterInstance }

	local distance = castDistance or MovementConstants.GroundQueryCastDistance
	local result = Workspace:Raycast(rootPart.Position, Vector3.new(0, -distance, 0), params)
	if not result then
		return nil
	end

	return {
		position = result.Position,
		normal = result.Normal,
	}
end

local function flattenDirection(direction: Vector3): Vector3?
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude == 0 then
		return nil
	end
	return flat.Unit
end

-- Wall detection (TRAVERSAL-ROADMAP.md §8 Phase 4, mechanic 4): a low and a
-- high forward raycast (near the feet and near the head of a standard R6
-- rig) must BOTH hit, and the low hit's normal must read close to
-- horizontal (`|normal:Dot(up)| <= maxUpDot`) to reject a ramp/slope or a
-- ceiling reading as a "wall." The reference's third check ("a floor
-- raycast must miss") is deliberately not ported -- it's redundant here,
-- since WallRun/WallLatch's own `CanEnter` (Shared/Movement/StateRules.luau)
-- already requires `not context.grounded`, so a real floor is never present
-- by the time this runs.
--
-- `castDirection` is caller-supplied (`humanoid.MoveDirection`, flattened),
-- not derived from `rootPart.CFrame.LookVector` -- facing lags real movement
-- input while the camera is unlocked (`FacingController`), so casting along
-- facing tests the wrong direction whenever facing hasn't caught up yet.
function SpatialQueries.QueryWall(
	rootPart: BasePart,
	filterInstance: Instance,
	castDirection: Vector3,
	rayLength: number?,
	maxUpDot: number?
): WallQueryResult?
	local flatForward = flattenDirection(castDirection)
	if not flatForward then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { filterInstance }

	local length = rayLength or MovementConstants.WallDetectRayLength
	local lowOrigin = rootPart.Position + Vector3.new(0, MovementConstants.WallDetectLowRayOffset, 0)
	local highOrigin = rootPart.Position + Vector3.new(0, MovementConstants.WallDetectHighRayOffset, 0)

	local lowResult = Workspace:Raycast(lowOrigin, flatForward * length, params)
	local highResult = Workspace:Raycast(highOrigin, flatForward * length, params)
	if not lowResult or not highResult then
		return nil
	end

	local threshold = maxUpDot or MovementConstants.WallDetectMaxUpDot
	if math.abs(lowResult.Normal:Dot(UP)) > threshold then
		return nil
	end

	return {
		position = lowResult.Position,
		normal = lowResult.Normal,
	}
end

-- Ledge check (mechanic 5): the SAME low forward raycast as QueryWall above,
-- but requires the HIGH ray to MISS -- "wall at your feet, open air above."
function SpatialQueries.QueryLedgeAbove(
	rootPart: BasePart,
	filterInstance: Instance,
	castDirection: Vector3,
	rayLength: number?
): boolean
	local flatForward = flattenDirection(castDirection)
	if not flatForward then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { filterInstance }

	local length = rayLength or MovementConstants.WallDetectRayLength
	local lowOrigin = rootPart.Position + Vector3.new(0, MovementConstants.WallDetectLowRayOffset, 0)
	local highOrigin = rootPart.Position + Vector3.new(0, MovementConstants.WallDetectHighRayOffset, 0)

	local lowResult = Workspace:Raycast(lowOrigin, flatForward * length, params)
	local highResult = Workspace:Raycast(highOrigin, flatForward * length, params)

	return lowResult ~= nil and highResult == nil
end

return SpatialQueries
