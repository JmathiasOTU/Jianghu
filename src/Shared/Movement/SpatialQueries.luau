--!strict
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

-- Temporary diagnostic capture for the 2026-09-19 "WallCling never triggers"
-- playtest report -- same `*_DEBUG_LOGGING` convention every other opt-in
-- print in this codebase already follows (e.g. MovementValidationService's
-- WALL_TRAVERSAL_DEBUG_LOGGING), printing exactly which gate rejected the
-- cast instead of guessing at a fix. Root cause confirmed via a real capture
-- (2026-09-19): every rejected hit showed `Anchored=false` on the test wall --
-- working as designed (v1 scope requires Anchored == true), not a code bug.
-- Off by default now that it's confirmed; flip back on if a NEW rejection
-- pattern shows up.
local WALLCLING_DEBUG_LOGGING = false

-- Pure geometry reads (TRAVERSAL-ROADMAP.md §3) -- called identically by
-- client prediction (via `CharacterMover:QueryGround`) and server
-- resimulation (`MovementValidationService`), so both sides can only ever
-- agree or disagree about the SAME raycast, never two independently
-- hand-synced copies of "how do we detect the ground." No stored state of
-- its own -- nothing here needs a Trove or a cleanup path.
local SpatialQueries = {}

-- One reusable RaycastParams per filter shape instead of one per cast (audit
-- M-021: up to ~1,000 casts/s server-side at 50 airborne players). Safe to
-- share because every cast here is synchronous and sets its own filter first.
local excludeParams = RaycastParams.new()
excludeParams.FilterType = Enum.RaycastFilterType.Exclude

local supportParams = RaycastParams.new()
supportParams.FilterType = Enum.RaycastFilterType.Exclude
supportParams.RespectCanCollide = true
supportParams.IgnoreWater = true

local function excluding(params: RaycastParams, filterInstance: Instance): RaycastParams
	params.FilterDescendantsInstances = { filterInstance }
	return params
end

export type GroundQueryResult = {
	position: Vector3,
	normal: Vector3,
}

export type WallRunQueryResult = {
	position: Vector3,
	normal: Vector3,
	side: "Left" | "Right",
	-- The hit part itself (docs/WallClimbingPlan.md §2/§9) -- added alongside
	-- WallCling so a wall-leap's launch wall can be remembered (the "cling
	-- back onto the wall you just leapt from" block). Existing WallRun/WallLeap
	-- callers only ever read position/normal/side, so this is purely additive.
	instance: BasePart,
}

export type ClingWallHit = {
	instance: BasePart,
	position: Vector3,
	normal: Vector3,
	distance: number,
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
	local params = excluding(excludeParams, filterInstance)

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

export type SupportHit = {
	floorVelocity: Vector3,
}

-- Server-side "is this character actually standing on something" check
-- (audit M-004): the Humanoid state label is written by the network-owning
-- client, so the server never treats it as proof of ground contact on its
-- own. Sweeps the R6 leg footprint straight down from the root; only
-- collidable, non-water geometry counts, so a CanCollide=false trigger volume
-- can't be "stood on". Also returns the floor's own velocity at the contact
-- point (audit M-014): a character standing on a moving platform, a vehicle
-- seat or another player is carried at that speed on top of its own.
function SpatialQueries.QuerySupport(rootPart: BasePart, filterInstance: Instance): SupportHit?
	local params = excluding(supportParams, filterInstance)

	local origin = CFrame.new(rootPart.Position)
	local direction = Vector3.new(0, -MovementConstants.GroundQueryCastDistance, 0)
	local result =
		Workspace:Blockcast(origin, MovementConstants.GroundSupportFootprint, direction, params)
	if not result then
		return nil
	end
	local floor = result.Instance
	return {
		floorVelocity = if floor:IsA("BasePart")
			then floor:GetVelocityAtPosition(result.Position)
			else Vector3.zero,
	}
end

-- Is there something collidable right in front of the torso to climb (ladder
-- rungs, a TrussPart)? The server's check that a Humanoid claiming the
-- Climbing state is really on something climbable (designer answer
-- 2026-09-24: ladders are in scope). Deliberately looser than castClingWall
-- -- rungs can be thin, round or unanchored -- because it only unlocks the
-- climb-rate allowance, never a velocity or a cap raise.
function SpatialQueries.QueryClimbable(rootPart: BasePart, filterInstance: Instance): boolean
	local params = excluding(supportParams, filterInstance)

	local lookVector = rootPart.CFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude < MovementConstants.DirectionEpsilon then
		return false
	end
	flatLook = flatLook.Unit

	local origin = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook)
	return Workspace:Blockcast(
		origin,
		MovementConstants.WallClingCastSize,
		flatLook * MovementConstants.WallClingDistance,
		params
	) ~= nil
end

-- Is the root inside terrain water? The server's check that a Humanoid
-- claiming the Swimming state is really in water (designer answer
-- 2026-09-24: swimming is in scope). Reads the voxels around the root.
function SpatialQueries.IsInWater(position: Vector3): boolean
	local terrain = Workspace.Terrain
	local half = Vector3.one * (MovementConstants.TerrainVoxelSize / 2)
	local region = Region3.new(position - half, position + half)
		:ExpandToGrid(MovementConstants.TerrainVoxelSize)
	local materials, occupancies = terrain:ReadVoxels(region, MovementConstants.TerrainVoxelSize)
	for x, plane in ipairs(materials) do
		for y, row in ipairs(plane) do
			for z, material in ipairs(row) do
				if material == Enum.Material.Water and occupancies[x][y][z] > 0 then
					return true
				end
			end
		end
	end
	return false
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
	local params = excluding(excludeParams, filterInstance)

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
			instance = result.Instance,
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

-- WallCling's facing-angle gate (docs/WallClimbingPlan.md §2/§7): head-on to
-- the wall, not side-on like wall run -- angle between the flattened look
-- vector and the flattened INWARD wall direction (negated normal), in
-- degrees. Zero on either flattened vector (looking straight up/down, or a
-- perfectly horizontal wall normal, neither of which real gameplay hits)
-- returns 180 (maximally not-facing) rather than dividing by a zero
-- magnitude, same "clamp rather than NaN" convention as TraversalMath.AngleBetween.
function SpatialQueries.facingAngleToWallDegrees(lookVector: Vector3, wallNormal: Vector3): number
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	local flatInward = Vector3.new(-wallNormal.X, 0, -wallNormal.Z)
	if
		flatLook.Magnitude < MovementConstants.DirectionEpsilon
		or flatInward.Magnitude < MovementConstants.DirectionEpsilon
	then
		return 180
	end
	local cosine = math.clamp(flatLook.Unit:Dot(flatInward.Unit), -1, 1)
	return math.deg(math.acos(cosine))
end

-- WallCling's own entry/sustain probe (docs/WallClimbingPlan.md §7) -- same
-- calling convention as QueryGround/QueryWallRun above: takes the rootPart
-- and the caller's own filter instance, derives its own RaycastParams and
-- look direction (`rootPart.CFrame.LookVector`, flattened) rather than
-- taking a `world`/pre-built `RaycastParams` from the caller -- there's only
-- ever one `Workspace` per execution context (client vs. server each already
-- resolve it to their OWN trusted tree), so a `WorldRoot` passthrough
-- parameter would add indirection this module's own established pattern
-- doesn't use anywhere else. A forward Blockcast (not WallRun's side-cast:
-- cling is head-on by design, see `facingAngleToWallDegrees` below), sized to
-- span roughly body height so thin slivers/corners don't register.
--
-- Deliberately does NOT gate on facing angle -- only structural legality
-- (a real, static, collidable wall) lives here, the exact same split
-- QueryWallRun/CanEnter[WallRun] already established: this cast finds the
-- wall, `CanEnter[WallCling]` judges whether the approach angle is good
-- enough against `constants.WallClingMaxFacingAngleDegrees` (a live-tunable
-- gameplay-feel dial, docs/WallClimbingPlan.md's own F4 tuning request) --
-- baking it in here would make it permanently fixed instead. No slack/options
-- parameter on the structural side -- client and server run the identical
-- thresholds there (docs/ARCHITECTURE.md §9).
function SpatialQueries.castClingWall(rootPart: BasePart, filterInstance: Instance): ClingWallHit?
	local params = excluding(excludeParams, filterInstance)

	local lookVector = rootPart.CFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude < MovementConstants.DirectionEpsilon then
		return nil
	end
	flatLook = flatLook.Unit

	local castOrigin = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook)
	local castDirection = flatLook * MovementConstants.WallClingDistance
	local result =
		Workspace:Blockcast(castOrigin, MovementConstants.WallClingCastSize, castDirection, params)
	if not result then
		if WALLCLING_DEBUG_LOGGING then
			print(
				string.format(
					"[WallCling] no Blockcast hit (origin=%s dir=%s size=%s)",
					tostring(castOrigin.Position),
					tostring(castDirection),
					tostring(MovementConstants.WallClingCastSize)
				)
			)
		end
		return nil
	end

	local instance = result.Instance
	if not instance:IsA("BasePart") or not instance.CanCollide or not instance.Anchored then
		if WALLCLING_DEBUG_LOGGING then
			print(
				string.format(
					"[WallCling] rejected hit %s: IsBasePart=%s CanCollide=%s Anchored=%s",
					instance:GetFullName(),
					tostring(instance:IsA("BasePart")),
					tostring(instance:IsA("BasePart") and instance.CanCollide),
					tostring(instance:IsA("BasePart") and instance.Anchored)
				)
			)
		end
		return nil
	end
	-- A shapecast that starts inside geometry can return a hit at distance 0
	-- with a zero normal -- guards against that degenerate case rather than
	-- feeding a zero vector into the verticality check below.
	if result.Normal.Magnitude < MovementConstants.DirectionEpsilon then
		if WALLCLING_DEBUG_LOGGING then
			print(string.format("[WallCling] rejected %s: zero normal", instance.Name))
		end
		return nil
	end
	if math.abs(result.Normal.Y) > MovementConstants.WallClingMaxNormalY then
		if WALLCLING_DEBUG_LOGGING then
			print(
				string.format(
					"[WallCling] rejected %s: normal.Y=%.3f (need <= %.3f)",
					instance.Name,
					result.Normal.Y,
					MovementConstants.WallClingMaxNormalY
				)
			)
		end
		return nil
	end

	if WALLCLING_DEBUG_LOGGING then
		print(string.format("[WallCling] ACCEPTED %s (structural gates passed)", instance.Name))
	end

	return {
		instance = instance,
		position = result.Position,
		normal = result.Normal,
		distance = result.Distance,
	}
end

return SpatialQueries
