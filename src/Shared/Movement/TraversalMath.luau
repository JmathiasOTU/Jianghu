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
function TraversalMath.DoubleJumpVerticalVelocity(
	elapsed: number,
	force: number,
	decayDuration: number
): number
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

-- WallRun tangent direction (Wall Run & Leap Mechanic Guideline §2): rotate
-- the wall normal 90 degrees around world up, then pick whichever of the two
-- resulting directions agrees with current momentum -- a wall run always
-- CONTINUES the direction you were already moving, never reverses you onto
-- the wall backwards. Zero `horizontalVelocity` keeps the raw (unsigned)
-- rotation -- real entry is separately gated on a minimum speed
-- (WallRunMinEntrySpeed), so this is never asked to pick a sign with no real
-- momentum behind it in practice.
function TraversalMath.WallRunTangent(normal: Vector3, horizontalVelocity: Vector3): Vector3
	local tangent = Vector3.new(-normal.Z, 0, normal.X)
	if tangent.Magnitude == 0 then
		return Vector3.zero
	end
	tangent = tangent.Unit

	if horizontalVelocity.Magnitude > 0 and tangent:Dot(horizontalVelocity.Unit) < 0 then
		tangent = -tangent
	end

	return tangent
end

-- Angle between two directions, in degrees (guideline §3's corner/curve
-- snap-off check: live wall normal vs. the locked entry normal). Zero
-- vectors clamp Dot to the nearest valid range rather than producing NaN.
function TraversalMath.AngleBetween(a: Vector3, b: Vector3): number
	if a.Magnitude == 0 or b.Magnitude == 0 then
		return 0
	end
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
end

-- WallLeap launch vector (guideline §4, redesigned 2026-09-18 from a
-- retention-scaled forward component to a flat additive burst -- the
-- original "forward = tangent * max(entrySpeed, minSpeed) * forwardRetention"
-- shaped a fixed curve out of the run's own entry speed; this instead keeps
-- whatever speed you actually have right now and adds a flat burst on top,
-- so it reads as a momentum kick rather than a scripted trajectory). Three
-- components: current velocity direction/magnitude plus a flat burst along
-- it, a fixed push-off away from the wall so the leap actually clears it
-- (still needed -- WallRun's own velocity is purely tangential, with no
-- away-from-wall component, so nothing else moves you clear of the surface),
-- and a fixed upward arc (deliberately flat, not a decaying impulse like
-- DoubleJump's -- one clean launch, not a sustained float). Raw numeric
-- params, not the whole EffectiveMovementConstants table, matching this
-- module's own existing convention (SlideSlopeAmplification etc.).
function TraversalMath.WallLeapVelocity(
	velocityDirection: Vector3,
	currentSpeed: number,
	wallNormal: Vector3,
	burstForce: number,
	pushForce: number,
	upwardForce: number
): Vector3
	local forward = velocityDirection * (currentSpeed + burstForce)
	local pushOff = wallNormal * pushForce
	return Vector3.new(forward.X + pushOff.X, upwardForce, forward.Z + pushOff.Z)
end

return TraversalMath
