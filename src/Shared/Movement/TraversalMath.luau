--!strict

-- Pure functions, one per traversal move (TRAVERSAL-ROADMAP.md §3/§9) --
-- client prediction and server resimulation both call these directly rather
-- than each keeping their own copy of the formula, which is the whole point
-- of the "full trajectory resimulation" decision (§0/§7): resimulation only
-- agrees with the client if both sides run the literal same math, not two
-- hand-synced copies. No stored state of any kind here -- nothing in this
-- module needs a Trove or a cleanup path.

local TraversalMath = {}

local UP = Vector3.new(0, 1, 0)

-- DoubleJump vertical impulse (mechanic 2, §9): starts at `force`, decays
-- toward roughly half of itself by `decayDuration`, then holds at that floor
-- for any elapsed time beyond it (the state itself is responsible for exiting
-- back to Airborne once its own duration/landing condition is met -- this
-- function only ever describes "what should the impulse read right now",
-- never when to stop applying it).
function TraversalMath.DoubleJumpVerticalVelocity(elapsed: number, force: number, decayDuration: number): number
	local t = if decayDuration > 0 then math.clamp(elapsed / decayDuration, 0, 1) else 1
	return force * (1 - 0.5 * t)
end

-- Slide slope angle off the ground normal (mechanic 3a, TRAVERSAL-ROADMAP.md
-- §9): 0 on flat ground, increasing as the surface tilts toward vertical.
-- Shared by client prediction and server resimulation, both fed off the SAME
-- `SpatialQueries.QueryGround` normal -- never two independently-read copies.
function TraversalMath.SlopeAngleRadians(groundNormal: Vector3): number
	return math.acos(math.clamp(groundNormal:Dot(UP), -1, 1))
end

-- Downhill direction along the slope's own surface (mechanic 3b): the ground
-- normal's tangent-plane projection of world-down -- "which way would a ball
-- roll from here." Returns the zero vector on perfectly flat ground (nothing
-- to roll toward, `groundNormal == UP`) -- callers must check magnitude
-- before normalizing, same convention as every other direction-producing
-- function in this module.
function TraversalMath.SlopeDownhillDirection(groundNormal: Vector3): Vector3
	local downhill = -(groundNormal:Cross(groundNormal:Cross(UP)))
	if downhill.Magnitude == 0 then
		return Vector3.zero
	end
	return downhill.Unit
end

-- Slide slope amplification (mechanic 3c): extra speed (studs/s) layered on
-- top of Slide's own dt-integrated linear decay when moving downhill on a
-- steep-enough slope -- this is an ADDITIVE top-up applied only to the
-- velocity actually output this tick, never fed back into the decaying base
-- itself, so the existing closed-form "(entrySpeed - CrouchSpeed) /
-- SlideDecayRate" duration stays true regardless of terrain (docs/MOVEMENT.md
-- §9's own decay design, preserved per TRAVERSAL-ROADMAP.md §9 mechanic 3's
-- note that only the slope math is ported, not the reference's whole decay
-- curve).
--
-- Zero below `thresholdRadians` (gates out raycast/geometry noise on
-- near-flat ground, not a real slope) or when `moveDirection` isn't pointed
-- generally downhill; ramps linearly from 0 to `amplificationCap` as the
-- angle goes from 0 to `maxWalkableRadians` (clamped at the cap beyond that
-- -- steeper than "walkable" doesn't add more).
function TraversalMath.SlideSlopeAmplification(
	groundNormal: Vector3,
	moveDirection: Vector3,
	thresholdRadians: number,
	maxWalkableRadians: number,
	amplificationCap: number
): number
	if moveDirection.Magnitude == 0 then
		return 0
	end

	local angle = TraversalMath.SlopeAngleRadians(groundNormal)
	if angle <= thresholdRadians then
		return 0
	end

	local downhill = TraversalMath.SlopeDownhillDirection(groundNormal)
	if downhill.Magnitude == 0 or moveDirection.Unit:Dot(downhill) <= 0 then
		return 0
	end

	local ratio = if maxWalkableRadians > 0 then math.clamp(angle / maxWalkableRadians, 0, 1) else 1
	return amplificationCap * ratio
end

-- Wall-run tangent velocity (mechanic 4, generalized, TRAVERSAL-ROADMAP.md
-- §8 Phase 4): projects `moveDirection` onto the wall's own vertical tangent
-- plane -- removes the "into the wall" component (the part parallel to the
-- wall's flattened normal) so the player is carried ALONG the surface rather
-- than pinned against or pushed off it -- then re-applies `speed` as the
-- output vector's magnitude. Returns the zero vector when there's nothing
-- left to run along (moving straight into/out of the wall with no lateral
-- component, or a normal with no horizontal component at all, e.g. a floor)
-- -- callers (WallRunState) treat a zero result as "nothing to do here,"
-- same convention `SlopeDownhillDirection` already establishes for its own
-- degenerate case.
function TraversalMath.WallRunTangentVelocity(wallNormal: Vector3, moveDirection: Vector3, speed: number): Vector3
	local flatNormal = Vector3.new(wallNormal.X, 0, wallNormal.Z)
	if flatNormal.Magnitude == 0 or moveDirection.Magnitude == 0 then
		return Vector3.zero
	end
	flatNormal = flatNormal.Unit

	local tangent = moveDirection - flatNormal * moveDirection:Dot(flatNormal)
	if tangent.Magnitude == 0 then
		return Vector3.zero
	end
	return tangent.Unit * speed
end

return TraversalMath
