--!strict

-- Speed/jump tiers below are a starting point ("Fast & fluid" preset, chosen
-- 2026-09-13), not a final tuning pass -- retune after playtesting in Studio. See
-- docs/MOVEMENT.md §7 and commit a31e6d9 on why these aren't guessed placeholders.
local MovementConstants = {
	RunDoubleTapWindowSeconds = 0.3,
	SprintThresholdSeconds = 3,

	WalkSpeed = 18,
	RunSpeed = 28,
	SprintSpeed = 40,
	JumpPower = 55,

	-- MovementValidationService's server-side speed/delta-position sanity check
	-- (docs/MOVEMENT.md §5, Step 4): sampled over this interval rather than every
	-- Heartbeat, to smooth over normal CFrame-replication jitter from the
	-- network-owning client.
	SpeedCheckIntervalSeconds = 0.5,
	-- Grace multiplier on top of the current tier's speed cap for that same
	-- replication jitter plus latency. Flagged unmeasured in the 2026-09-13
	-- rubber-banding investigation (docs/MOVEMENT.md §5/§9) -- left unchanged
	-- rather than guessed upward, since the reported bug turned out to be
	-- structural (stale FSM-mirror desync + a transition-boundary transient),
	-- not this number being too tight. Revisit only with real measured data from
	-- SPEED_SANITY_DEBUG_LOGGING (`MovementValidationService.luau`).
	SpeedToleranceMultiplier = 1.3,

	-- Crouch/Slide (docs/MOVEMENT.md §9, Phase 1 slice 2) -- starting-point
	-- values chosen the same way the original speed tiers were ("Fast & fluid,"
	-- not yet playtested), not measured/tuned. All three flow through the live-
	-- tuning layer (Shared/Movement/MovementTuning.luau) like every other value
	-- above, so they're adjustable in Studio without a republish.
	--
	-- Half of WalkSpeed -- crouched movement should read as clearly slower than
	-- upright walking, not just a cosmetic pose change.
	CrouchSpeed = 9,
	-- LINEAR decay (studs/s lost per second), not exponential: chosen because it
	-- gives a slide a FIXED, predictable duration for a given entry speed
	-- (duration = (entrySpeed - CrouchSpeed) / SlideDecayRate) -- a level
	-- designer sizing a slide-gap or a player learning the feel can reason about
	-- "how far does a Sprint-speed slide carry me" as a fixed number, where an
	-- exponential decay's asymptotic "never quite reaches the target" curve
	-- would make that same question depend on an arbitrarily-chosen cutoff
	-- instead of a clean closed-form answer.
	SlideDecayRate = 20,
	-- Multiplies whatever REAL horizontal speed you had the instant Slide was
	-- entered (docs/MOVEMENT.md §12/playtest feedback 2026-09-15): decay rate
	-- alone controls how fast a slide slows down, but distance covered is a
	-- function of BOTH decay rate and entry speed
	-- (distance = (entrySpeed - CrouchSpeed)^2 / (2 * SlideDecayRate)) -- a
	-- Run-tier slide at the raw RunSpeed=28 entry only covers ~9 studs before
	-- SlideDecayRate=20 eats it down to CrouchSpeed, which read as "the decay
	-- feels right but the slide has no distance." This scales entry speed up
	-- (still proportional to however fast you were actually moving -- Sprint
	-- entries stay faster than Run entries, downhill residual momentum still
	-- carries through) rather than slowing decay down, which would have
	-- changed the deceleration feel that was already confirmed correct.
	-- `SlideJumpState`'s boost ceiling and the server's `maxSpeedForState`
	-- formula both scale by this same multiplier so a boosted slide doesn't
	-- immediately rubber-band against a cap sized for the old, unboosted
	-- ceiling. Starting-point value, not measured -- retune in Studio (F4
	-- Tuning tab) alongside SlideDecayRate until the ratio feels right.
	SlideEntrySpeedMultiplier = 1.25,
	-- Added to whatever speed Slide had decayed to at the moment of the jump
	-- (docs/MOVEMENT.md §9), then clamped to SprintSpeed -- SlideJump reuses
	-- the existing SprintSpeed ceiling rather than a new cap constant (same
	-- ceiling Slide/Airborne already share), so the boost can never itself be
	-- the reason a legitimate player gets rubber-banded.
	SlideJumpBoostAmount = 50,

	-- How forward-biased Sprint's continuation input must be to still count as
	-- "sprinting forward" rather than a backpedal/pure-strafe demotion, expressed
	-- as a dot-product threshold between facing and MoveDirection (1 = dead
	-- ahead, 0 = perpendicular). This is a gameplay-feel decision (like
	-- `SprintThresholdSeconds`), not a latency/replication tolerance: real WASD
	-- input only ever produces 0°, 45°, or 90°+ camera-relative angles (cos 0° =
	-- 1, cos 45° ≈ 0.707, cos 90° = 0), so any threshold comfortably between 0.707
	-- and 0 admits every legitimate forward-diagonal hold without change and only
	-- affects an angle no real keyboard combination can produce -- closing the
	-- gap where `MovementValidationService.classifyMoveIntent`'s old zero-crossing
	-- (`> 0`) let a spoofed `MoveDirection` with a razor-thin forward lean count
	-- as "forward" while moving almost entirely sideways (found 2026-09-13).
	SprintForwardDeadzone = 0.5,

	-- LocomotionAnimator's discrete switch-with-crossfade between whichever
	-- track is currently selected and the next (docs/MOVEMENT.md §4 -- "not a
	-- weighted multi-track blend tree") -- how long that crossfade takes,
	-- passed to both `AnimationTrack:Play`/`:Stop`. Moved here from a
	-- module-local constant in LocomotionAnimator.luau (2026-09-15 cleanup
	-- pass) to get the same live-tuning treatment `LandingAnimationHoldSeconds`
	-- right below already has -- adjustable from the F4 Tuning tab without a
	-- republish, since fade feel is exactly the kind of thing worth dialing in
	-- once real animations exist.
	AnimationFadeTimeSeconds = 0.15,

	-- Landing/falling animation (Traversal Roadmap §8 Phase 0, docs/MOVEMENT.md
	-- §10) -- original design, no reference source. How long the one-shot
	-- light `Land` clip is allowed to win over the landed-state's own
	-- animation key before falling through to normal per-state resolution --
	-- the FSM has already transitioned to Idle/Walk/etc. by the time landing
	-- is detected, so without this window the one-shot would never be seen at
	-- all. `HardLanding` (below) needs no equivalent hold: it's a real FSM
	-- state that persists for its own real duration, so per-state resolution
	-- already picks `LandHard` for as long as the lock lasts.
	LandingAnimationHoldSeconds = 0.19,

	-- HardLanding (real FSM state, docs/MOVEMENT.md §10 rework) -- the fall
	-- height (studs, peak height reached since last leaving the ground minus
	-- landing height -- NOT vertical speed; a height threshold is what "would
	-- take fall damage at this height" actually means, and is what a designer
	-- wants to dial in directly rather than back-computing from
	-- v = sqrt(2*g*h)) at or above which a landing forces the `HardLanding`
	-- lock instead of resolving normally to Idle/Walk/Run/Sprint/Crouch.
	-- Starting-point value, not measured -- retune in Studio (F4 Tuning tab)
	-- once real fall-damage numbers exist to anchor it to.
	HardLandingHeightThreshold = 40,
	-- How long `HardLanding` holds movement (WalkSpeed pinned to 0) and jump
	-- locked, once entered -- sized to the real `LandHard` clip's length so
	-- the lock and the animation end together. A fixed duration, not a
	-- read-the-clip's-own-Length like SlideJump's presentation-only animation
	-- hold (`OneShotAnimationHoldFallbackSeconds`, below): this number is
	-- gameplay-authoritative (the server mirrors it to enforce
	-- the lock, see `MovementValidationService.mirrorPassiveTransitions`), so
	-- client and server need to agree on the exact SAME number, which reading
	-- a client-local `AnimationTrack.Length` can never guarantee the server
	-- side of.
	HardLandingDurationSeconds = 1.11,

	-- DoubleJump (TRAVERSAL-ROADMAP.md §5/§8 Phase 1) -- starting-point values,
	-- not yet playtested, chosen the same "Fast & fluid" way as the original
	-- speed/jump tiers. Initial upward velocity applied on entry; decays
	-- toward roughly half of itself (Shared/Movement/TraversalMath.luau) over
	-- DoubleJumpDecayDurationSeconds, at which point the state hands back to
	-- Airborne (or straight to a grounded state, if it lands mid-impulse).
	DoubleJumpForce = 50,
	DoubleJumpDecayDurationSeconds = 0.45,

	-- Slide slope amplification (TRAVERSAL-ROADMAP.md §5/§8 Phase 3, mechanic
	-- 3a/3b/3c) -- ported from the reference's slope math, NOT its whole decay
	-- curve: `SlideDecayRate` above stays exactly the existing linear
	-- dt-integrated decay, this only adds an extra top-up on top of it when
	-- sliding downhill (Shared/Movement/TraversalMath.luau).
	--
	-- Below this angle (degrees, off the ground normal), no amplification
	-- applies at all -- gates out raycast/geometry noise on near-flat ground,
	-- not a real slope.
	SlideSlopeAngleThresholdDegrees = 5,
	-- The angle (degrees) at which amplification reaches its full cap --
	-- steeper doesn't add more (ratio clamps at 1.0). This is "the steepest
	-- slope still treated as walkable enough to slide down," not a hard
	-- geometry limit.
	SlideMaxWalkableSlopeDegrees = 8,
	-- Max EXTRA speed (studs/s) slope amplification can add, reached at
	-- SlideMaxWalkableSlopeDegrees. The reference used 45 directly for this
	-- same kind of magnitude -- deliberately tuned down here (per
	-- TRAVERSAL-ROADMAP.md §5's own "tune down" flag): 45 studs/s stacked on a
	-- 40 SprintSpeed base would more than double slide speed on a gentle 8°
	-- slope. Starting-point value, not measured -- retune after playtesting.
	SlideSlopeAmplificationCap = 12,
	-- Slide's ground-normal raycast is throttled via a delta-time accumulator
	-- (ARCHITECTURE.md §6 forbids a raw per-tick raycast) -- how often it
	-- actually re-fires, not every Heartbeat.
	SlideGroundRaycastThrottleSeconds = 0.1,

	-- Server-only anti-cheat plumbing (MovementValidationService), not a
	-- gameplay-feel number -- deliberately NOT in MovementTuning's live-tunable
	-- set, same reasoning as SpeedCheckIntervalSeconds above. The moment a
	-- ClaimTraversalMove is accepted, the speed-sanity baseline resets and the
	-- horizontal check is suspended for this long (TRAVERSAL-ROADMAP.md §7.4)
	-- before resuming against the resimulated position -- otherwise a
	-- legitimate traversal move's own residual momentum on landing gets
	-- flagged as a violation the instant it lands.
	TraversalSpeedSanityGraceSeconds = 0.5,

	-- Presentation-only animation hold fallback shared by every one-shot,
	-- synchronous-frame state (LocomotionAnimator.luau's `_transientHold`) --
	-- used only if the real AnimationTrack's Length reads 0 (should never
	-- happen once a real clip is authored). Not gameplay-authoritative (unlike
	-- HardLandingDurationSeconds, which the server also enforces), so
	-- deliberately NOT in MovementTuning's live-tunable set, same reasoning as
	-- SpeedCheckIntervalSeconds/TraversalSpeedSanityGraceSeconds above.
	OneShotAnimationHoldFallbackSeconds = 0.55,

	-- Ground raycast structural reach (Shared/Movement/SpatialQueries.luau,
	-- moved here from a module-local constant in the 2026-09-15 cleanup pass)
	-- -- long enough to reach the ground from HumanoidRootPart's own height
	-- above it on a standard R6 rig, plus slack for slopes/stairs, without
	-- reaching so far it hits floors through real gaps. Structural (raycast
	-- reach), not a gameplay-feel number -- deliberately NOT in MovementTuning's
	-- live-tunable set, same reasoning as SpeedCheckIntervalSeconds/
	-- TraversalSpeedSanityGraceSeconds above.
	GroundQueryCastDistance = 4,

	-- WallRun side-cast (Wall Run & Leap Mechanic Guideline §1/§7).
	-- Shapecast sphere radius for QueryWallRun.
	WallRunSideCastRadius = 1.5,
	-- Structural cast reach, not live-tunable -- same exclusion as
	-- GroundQueryCastDistance. Kept short on purpose: this distance is also
	-- what stops WallRun's entry from stealing a DoubleJump press (§0/§7).
	WallRunSideCastDistance = 3.5,
	-- Flatness gate: a side-cast hit only counts as a wall if its normal's
	-- dot with world-up is at or below this.
	WallDetectMaxUpDot = 0.3,
	-- QueryWallRun's own throttle, same dt-accumulator idiom as
	-- SlideGroundRaycastThrottleSeconds.
	WallRunQueryThrottleSeconds = 0.1,
	-- CanEnter[WallRun]'s momentum gate (guideline §2) -- no wall run from a
	-- standstill jump.
	WallRunMinEntrySpeed = 10,
	-- CanEnter[WallRun]'s alignment gate (guideline §2), a dot-product
	-- threshold against the signed wall tangent -- same "comfortably admits
	-- real WASD angles" idiom as SprintForwardDeadzone.
	WallRunEntryDotThreshold = 0.5,
	-- Locked horizontal speed while running (guideline §3) -- kept at/under
	-- SprintSpeed on purpose so the still-pending server validation (§6) can't
	-- false-positive against Airborne's own speed-sanity ceiling in the
	-- meantime (docs/MOVEMENT.md §5).
	WallRunSpeed = 35,
	-- Controlled vertical sink while running -- the "gravity-defying" tuning
	-- knob, not zero (a hover) and not full gravity.
	WallRunSinkSpeed = 6,
	-- Target perpendicular distance from the wall surface (guideline §3's
	-- cling snap/hold) -- roughly an R6 torso-width offset.
	WallRunClingDistance = 2,
	-- P-controller gain for the continuous hold correction.
	WallRunClingCorrectionRate = 8,
	-- Clamp on the hold correction so a post-corner re-settle is firm, never a
	-- jolt.
	WallRunClingMaxCorrectionSpeed = 20,
	-- Corner/curve snap-off budget: live wall normal vs. the locked entry
	-- normal, in degrees.
	WallRunMaxNormalDeviationDegrees = 35,
	-- Safety duration cap -- Qinggong drain is meant to own the real duration
	-- once that resource exists (still math.huge/always-available for now).
	WallRunMaxDurationSeconds = 3,
	-- WallLeap launch vector (guideline §4, redesigned 2026-09-18): flat
	-- momentum burst added on top of whatever horizontal speed you actually
	-- have at leap time, along that same direction -- a kick, not a
	-- retention-scaled curve.
	WallLeapBurstForce = 75,
	-- Fixed lateral push-away-from-wall magnitude.
	WallLeapPushForce = 75,
	-- Fixed vertical arc magnitude -- a flat constant, not a decaying
	-- impulse like DoubleJump's.
	WallLeapUpwardForce = 100,
}

return MovementConstants
