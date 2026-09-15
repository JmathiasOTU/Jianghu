--!strict
local Workspace = game:GetService("Workspace")

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

-- Default downward cast length: long enough to reach the ground from
-- HumanoidRootPart's own height above it on a standard R6 rig, plus slack for
-- slopes/stairs, without reaching so far it hits floors through real gaps.
local DEFAULT_GROUND_CAST_DISTANCE = 4

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

	local distance = castDistance or DEFAULT_GROUND_CAST_DISTANCE
	local result = Workspace:Raycast(rootPart.Position, Vector3.new(0, -distance, 0), params)
	if not result then
		return nil
	end

	return {
		position = result.Position,
		normal = result.Normal,
	}
end

return SpatialQueries
