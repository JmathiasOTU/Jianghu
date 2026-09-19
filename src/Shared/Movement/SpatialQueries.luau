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

export type GroundQueryResult = {
	position: Vector3,
	normal: Vector3,
}

export type WallRunQueryResult = {
	position: Vector3,
	normal: Vector3,
	side: "Left" | "Right",
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

-- WallRun's own entry/sustain probe (Wall Run & Leap Mechanic Guideline §1) --
-- a side-cast along the root part's own RightVector, not a forward cast, so a
-- shallow-angle approach along the wall still hits it (the reverted forward
-- QueryWall never did, see docs/MOVEMENT.md §13). Sphere-shaped so gaps/trim/
-- rounded geometry still register, unlike a thin raycast. Closer side wins if
-- both hit (e.g. a narrow alley).
function SpatialQueries.QueryWallRun(
	rootPart: BasePart,
	filterInstance: Instance,
	castRadius: number?,
	castDistance: number?
): WallRunQueryResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { filterInstance }

	local radius = castRadius or MovementConstants.WallRunSideCastRadius
	local distance = castDistance or MovementConstants.WallRunSideCastDistance
	local origin = rootPart.Position
	local right = rootPart.CFrame.RightVector

	local function castSide(direction: Vector3, side: "Left" | "Right"): WallRunQueryResult?
		-- Pull the sweep's start back opposite `direction` by `radius`, and
		-- extend the swept distance by the same amount, so the sphere's
		-- LEADING edge starts exactly at `origin` rather than the sphere
		-- itself starting centered there. Roblox's Shapecast/Spherecast never
		-- registers a hit against a part the shape already overlaps at the
		-- start of the sweep (documented behavior, not a bug in this code) --
		-- without this, a player standing close enough to a wall that the
		-- un-adjusted radius-1.5 sphere already overlapped it (very plausible
		-- for R6's own ~1-stud torso half-width) would silently never
		-- register a hit at all, which is exactly the "too close, won't
		-- activate" symptom this fixes.
		local pulledBackOrigin = origin - direction * radius
		local result =
			Workspace:Spherecast(pulledBackOrigin, radius, direction * (distance + radius), params)
		if not result then
			return nil
		end
		if math.abs(result.Normal:Dot(Vector3.yAxis)) > MovementConstants.WallDetectMaxUpDot then
			return nil
		end
		return {
			position = result.Position,
			normal = result.Normal,
			side = side,
		}
	end

	local rightHit = castSide(right, "Right")
	local leftHit = castSide(-right, "Left")

	if rightHit and leftHit then
		local rightDistance = (rightHit.position - origin).Magnitude
		local leftDistance = (leftHit.position - origin).Magnitude
		return if rightDistance <= leftDistance then rightHit else leftHit
	end

	return rightHit or leftHit
end

return SpatialQueries
