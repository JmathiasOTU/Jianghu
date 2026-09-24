--!strict

-- Pure functions, one per traversal move (docs/MovementSystem.md §2/§4) --
-- client prediction and server resimulation both call these directly rather
-- than each keeping their own copy of the formula, which is the whole point
-- of the "full trajectory resimulation" decision (§0/§7): resimulation only
-- agrees with the client if both sides run the literal same math, not two
-- hand-synced copies. No stored state of any kind here -- nothing in this
-- module needs a Trove or a cleanup path.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local TraversalMath = {}

local UP = Vector3.new(0, 1, 0)
local EPSILON = MovementConstants.DirectionEpsilon
local DOUBLE_JUMP_FLOOR = MovementConstants.DoubleJumpDecayFloorFraction

-- WallBoost's launch vector (docs/MovementSystem.md §4.6) -- an instant,
-- flat impulse: a small separation push away from the wall (so the character
-- doesn't snag on wall friction while rising) plus a fixed upward force.
-- Takes raw numeric params (`upwardForce`/`separationSpeed`), matching this
-- module's own existing convention (e.g. WallLeapVelocity's burst/push/upward
-- params) rather than the whole MovementConstants table.
function TraversalMath.WallBoostVelocity(
	wallNormal: Vector3,
	upwardForce: number,
	separationSpeed: number
): Vector3
	local away = Vector3.new(wallNormal.X, 0, wallNormal.Z)
	local separation = Vector3.zero
	if away.Magnitude > EPSILON then
		separation = away.Unit * separationSpeed
	end
	return Vector3.new(separation.X, upwardForce, separation.Z)
end

-- How tall a gap one boost clears (docs/MovementSystem.md §4.6) -- for level
-- designers and tests, not consulted by any runtime enforcement path.
function TraversalMath.WallBoostPeakHeight(upwardForce: number, gravity: number): number
	return upwardForce ^ 2 / (2 * gravity)
end

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
	return force * (1 - (1 - DOUBLE_JUMP_FLOOR) * t)
end

-- Height gained by a body launched straight up at `verticalSpeed` under
-- gravity alone. Used by the server's vertical ceiling (audit M-001) for every
-- one-shot vertical launch: the Humanoid's own jump (JumpPower), WallLeap and
-- WallBoost all REPLACE vertical velocity rather than add to it.
function TraversalMath.BallisticRise(verticalSpeed: number, gravity: number): number
	local speed = math.max(verticalSpeed, 0)
	return speed * speed / (2 * gravity)
end

-- Seconds from a vertical launch at `verticalSpeed` until gravity stops it
-- (re-audit N-002): the latest moment a one-shot launch can still be rising.
function TraversalMath.TimeToApex(verticalSpeed: number, gravity: number): number
	return math.max(verticalSpeed, 0) / gravity
end

-- Highest Y a free-falling body can be at `now` (re-audit N-001/N-002): it
-- can't be above `apexY`, and once `apexAt` has passed nothing is holding it
-- up, so it's at best falling from `apexY` from rest. Every built-in launch
-- replaces vertical velocity, so a later launch moves both inputs rather than
-- adding to this curve.
function TraversalMath.DescentCeiling(
	apexY: number,
	apexAt: number,
	now: number,
	gravity: number
): number
	local falling = now - apexAt
	if falling <= 0 then
		return apexY
	end
	return apexY - gravity * falling * falling / 2
end

-- Latest moment DoubleJump can still be rising (re-audit N-002), paired with
-- `DoubleJumpMaxRise` as the apex. The held phase lasts `decayDuration` plus
-- up to one client frame (Update notices the end a frame late), then releases
-- into a ballistic arc at the curve's last sampled value. Bounding that
-- release by the curve's own maximum, `force`, instead of its end value
-- absorbs the late frame: the difference covers a frame of up to
-- (1 - floor) * force / g, less the extra release speed that late frame buys
-- (about 0.1 s, i.e. clients at 10 fps or better at shipped tuning; the specs
-- check 20-240 fps). The bound only holds if this time is not early: the
-- descent check can't make up a late apex with extra height.
function TraversalMath.DoubleJumpTimeToApex(
	force: number,
	decayDuration: number,
	gravity: number
): number
	return decayDuration + TraversalMath.TimeToApex(force, gravity)
end

-- Upper bound on DoubleJump's total rise (audit M-001). The override holds
-- vertical speed at `DoubleJumpVerticalVelocity` (never above `force`) for
-- `decayDuration`, then releases at half of `force` into a ballistic arc.
-- Bounding the held phase by `force * decayDuration` (not the curve's exact
-- 0.75 integral) absorbs the client's per-frame sampling of that curve and
-- the one extra frame before its Update notices the window ended.
function TraversalMath.DoubleJumpMaxRise(
	force: number,
	decayDuration: number,
	gravity: number
): number
	return force * decayDuration + TraversalMath.BallisticRise(force * DOUBLE_JUMP_FLOOR, gravity)
end

-- Exact upper bound on WallLeap's horizontal launch speed (audit M-003),
-- derived from server-known constants only. During WallRun the horizontal
-- velocity is `tangent * runSpeed + normal * c` with |c| <= maxCorrection, and
-- the leap launches along that velocity's own direction at (speed + burst)
-- plus `push` along the wall normal. Every term of the resulting magnitude
-- grows with c, so the bound is taken at c = maxCorrection.
function TraversalMath.WallLeapMaxHorizontalSpeed(
	runSpeed: number,
	maxCorrection: number,
	burstForce: number,
	pushForce: number
): number
	local runVelocity = math.sqrt(runSpeed * runSpeed + maxCorrection * maxCorrection)
	if runVelocity == 0 then
		return burstForce + pushForce
	end
	local forward = runVelocity + burstForce
	local alongNormal = maxCorrection / runVelocity
	return math.sqrt(
		forward * forward + pushForce * pushForce + 2 * pushForce * forward * alongNormal
	)
end

-- Slide slope angle off the ground normal (mechanic 3a, docs/MovementSystem.md §4): 0 on flat
-- ground, increasing as the surface tilts toward vertical. Shared by client prediction and server
-- resimulation, both fed off the SAME `SpatialQueries.QueryGround` normal -- never two
-- independently-read copies.
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
-- SlideDecayRate" duration stays true regardless of terrain (docs/MovementSystem.md §4.2's own
-- decay design, preserved per docs/MovementSystem.md §4 mechanic 3's
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

-- WallRun tangent direction (docs/MovementSystem.md §4.5): rotate
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

-- Angle between two directions, in degrees (docs/MovementSystem.md §4.5's corner/curve
-- snap-off check: live wall normal vs. the locked entry normal). Zero
-- vectors clamp Dot to the nearest valid range rather than producing NaN.
function TraversalMath.AngleBetween(a: Vector3, b: Vector3): number
	if a.Magnitude == 0 or b.Magnitude == 0 then
		return 0
	end
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
end

-- WallLeap launch vector (docs/MovementSystem.md §4.5, redesigned 2026-09-18 from a
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
