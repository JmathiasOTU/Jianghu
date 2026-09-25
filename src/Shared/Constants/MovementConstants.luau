--!strict

-- Speed/jump tiers below are a starting point ("Fast & fluid" preset, chosen
-- 2026-09-13), not a final tuning pass -- retune after playtesting in Studio. See
-- docs/MovementSystem.md §2 and commit a31e6d9 on why these aren't guessed placeholders.
local MovementConstants = {
	RunDoubleTapWindowSeconds = 0.3,
	SprintThresholdSeconds = 3,

	WalkSpeed = 18,
	RunSpeed = 28,
	SprintSpeed = 40,
	JumpPower = 55,

	-- MovementValidationService's server-side speed/delta-position sanity check
	-- (docs/MovementSystem.md §8, Step 4): sampled over this interval rather than every
	-- Heartbeat, to smooth over normal CFrame-replication jitter from the
	-- network-owning client.
	SpeedCheckIntervalSeconds = 0.5,
	-- Grace multiplier on top of the accumulated speed budget for replication
	-- jitter. STILL UNMEASURED (audit M-007, ARCHITECTURE §9 violation until
	-- sized): turn on SPEED_RATIO_CAPTURE in MovementValidationService, play
	-- honestly (ideally with Studio's incoming replication lag), and set this to
	-- the reported p99.9 ratio, citing the capture here. Not live-tunable
	-- (audit M-017) -- a validation tolerance is measured, never dialled.
	SpeedToleranceMultiplier = 1.3,

	-- Crouch/Slide (docs/MovementSystem.md §4.2, Phase 1 slice 2) -- starting-point
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
	-- entered (docs/MovementSystem.md §4.2/playtest feedback 2026-09-15): decay rate
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
	-- (docs/MovementSystem.md §4.2), then clamped to Slide's own ceiling
	-- (SprintSpeed * SlideEntrySpeedMultiplier). That's above the Airborne
	-- cap, so the server gives the whole flight that ceiling as an allowance
	-- (MovementValidationService `airborneAllowedSpeed`); without it, the
	-- boost itself got legitimate players rubber-banded (2026-09-24).
	SlideJumpBoostAmount = 50,
	-- SlideJump's upward launch speed, set explicitly by SlideJumpState and
	-- used by the server's vertical ceiling (~10.1 studs of rise at default
	-- gravity vs. a normal jump's ~7.7). Before it existed, slide jumps
	-- launched at 61.9-63.7 studs/s from a side effect of the slide (measured
	-- 2026-09-24 with JUMP_LAUNCH_CAPTURE, vs. 56-58 for standing/running
	-- jumps) that the server didn't know about; the designer chose to keep that
	-- height on purpose (2026-09-24). Not live-tunable: a new tunable needs its
	-- own Studio-built overlay row.
	SlideJumpUpwardSpeed = 63,

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
	-- track is currently selected and the next (docs/MovementSystem.md §6 -- "not a
	-- weighted multi-track blend tree") -- how long that crossfade takes,
	-- passed to both `AnimationTrack:Play`/`:Stop`. Moved here from a
	-- module-local constant in LocomotionAnimator.luau (2026-09-15 cleanup
	-- pass) to get the same live-tuning treatment `LandingAnimationHoldSeconds`
	-- right below already has -- adjustable from the F4 Tuning tab without a
	-- republish, since fade feel is exactly the kind of thing worth dialing in
	-- once real animations exist.
	AnimationFadeTimeSeconds = 0.15,

	-- Landing/falling animation (docs/MovementSystem.md §4, docs/MovementSystem.md §4.4) --
	-- original design, no reference source. How long the one-shot
	-- light `Land` clip is allowed to win over the landed-state's own
	-- animation key before falling through to normal per-state resolution --
	-- the FSM has already transitioned to Idle/Walk/etc. by the time landing
	-- is detected, so without this window the one-shot would never be seen at
	-- all. `HardLanding` (below) needs no equivalent hold: it's a real FSM
	-- state that persists for its own real duration, so per-state resolution
	-- already picks `LandHard` for as long as the lock lasts.
	LandingAnimationHoldSeconds = 0.19,

	-- HardLanding (real FSM state, docs/MovementSystem.md §4.4 rework) -- the fall
	-- height (studs, peak height reached since last leaving the ground minus
	-- landing height -- NOT vertical speed; a height threshold is what "would
	-- take fall damage at this height" actually means, and is what a designer
	-- wants to dial in directly rather than back-computing from
	-- v = sqrt(2*g*h)) at or above which a landing forces the `HardLanding`
	-- lock instead of resolving normally to Idle/Walk/Run/Sprint/Crouch.
	-- Starting-point value, not measured -- retune in Studio (F4 Tuning tab)
	-- once real fall-damage numbers exist to anchor it to.
	HardLandingHeightThreshold = 120,
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

	-- MediumLanding: NOT a real FSM state (unlike HardLanding) -- a landing in
	-- this height band still resolves normally to Idle/Walk/Run/Sprint/Crouch,
	-- just with a brief "LandMedium" animation overlay and a temporary
	-- WalkSpeed multiplier, both timed to this one duration. Purely a
	-- movement-feel debuff, not a security-relevant cap (skipping it just
	-- means moving at your already-normal tier speed slightly early, never
	-- above any existing cap), so deliberately NOT mirrored server-side --
	-- same reasoning as OneShotAnimationHoldFallbackSeconds above. Live-tunable
	-- via the F4 Tuning tab (Shared/Movement/MovementTuning.luau), same as
	-- HardLanding's own pair -- starting-point values below, not measured.
	MediumLandingHeightThreshold = 60,
	MediumLandingDurationSeconds = 0.55,
	MediumLandingSpeedMultiplier = 0.7,

	-- DoubleJump (docs/MovementSystem.md §11/§4) -- starting-point values,
	-- not yet playtested, chosen the same "Fast & fluid" way as the original
	-- speed/jump tiers. Initial upward velocity applied on entry; decays
	-- toward roughly half of itself (Shared/Movement/TraversalMath.luau) over
	-- DoubleJumpDecayDurationSeconds, at which point the state hands back to
	-- Airborne (or straight to a grounded state, if it lands mid-impulse).
	DoubleJumpForce = 50,
	DoubleJumpDecayDurationSeconds = 0.45,
	-- Fraction of DoubleJumpForce the impulse has decayed to by the end of
	-- DoubleJumpDecayDurationSeconds. Shared by the client's impulse and the
	-- server's vertical ceiling, so it's a constant rather than a literal in
	-- TraversalMath (audit M-031). Not live-tunable: the server's rise bound
	-- depends on it.
	DoubleJumpDecayFloorFraction = 0.5,

	-- Slide slope amplification (docs/MovementSystem.md §11/§4, mechanic
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
	-- docs/MovementSystem.md §11's own "tune down" flag): 45 studs/s stacked on a
	-- 40 SprintSpeed base would more than double slide speed on a gentle 8°
	-- slope. Starting-point value, not measured -- retune after playtesting.
	SlideSlopeAmplificationCap = 12,
	-- Slide's ground-normal raycast is throttled via a delta-time accumulator
	-- (ARCHITECTURE.md §6 forbids a raw per-tick raycast) -- how often it
	-- actually re-fires, not every Heartbeat.
	SlideGroundRaycastThrottleSeconds = 0.1,

	-- Presentation-only animation hold fallback shared by every one-shot,
	-- synchronous-frame state (LocomotionAnimator.luau's `_transientHold`) --
	-- used only if the real AnimationTrack's Length reads 0 (should never
	-- happen once a real clip is authored). Not gameplay-authoritative (unlike
	-- HardLandingDurationSeconds, which the server also enforces), so
	-- deliberately NOT in MovementTuning's live-tunable set, same reasoning as
	-- SpeedCheckIntervalSeconds above.
	OneShotAnimationHoldFallbackSeconds = 0.55,

	-- Ground raycast structural reach (Shared/Movement/SpatialQueries.luau,
	-- moved here from a module-local constant in the 2026-09-15 cleanup pass)
	-- -- long enough to reach the ground from HumanoidRootPart's own height
	-- above it on a standard R6 rig, plus slack for slopes/stairs, without
	-- reaching so far it hits floors through real gaps. Structural (raycast
	-- reach), not a gameplay-feel number -- deliberately NOT in MovementTuning's
	-- live-tunable set, same reasoning as SpeedCheckIntervalSeconds above.
	-- Also the reach of the server's ground-support probe (QuerySupport).
	GroundQueryCastDistance = 4,
	-- Below this magnitude a flattened direction/normal is treated as zero
	-- rather than normalised (looking straight up, a degenerate cast normal).
	-- A numerical guard, not gameplay tuning.
	DirectionEpsilon = 1e-3,
	-- R6 rig geometry: HumanoidRootPart's centre sits 3 studs above the feet
	-- (2-stud legs + half of the 2-stud torso). A rig fact, not a tolerance.
	RigRootHeightAboveFeet = 3,
	-- R6 leg footprint (both legs side by side: 2 wide, 1 deep) swept down by
	-- QuerySupport, so a player standing on a ledge edge with the root centre
	-- over the void still reads as supported, matching the Humanoid's own
	-- floor sensing better than a single centre ray.
	GroundSupportFootprint = Vector3.new(2, 0.2, 1),
	-- Roblox terrain's fixed voxel resolution (Terrain:ReadVoxels requires it).
	-- An engine fact, not a tunable.
	TerrainVoxelSize = 4,
	-- CollectionService tag level authors put on a ladder (the rung parts or
	-- the model holding them) so the server accepts Humanoid climbing on it.
	-- TrussParts count without it. Anything else can't be climbed (re-audit
	-- N-004): the Climbing label comes from the client.
	ClimbableTag = "Climbable",

	-- WallRun side-cast (docs/MovementSystem.md §4.5/§11).
	-- Shapecast sphere radius for QueryWallRun.
	WallRunSideCastRadius = 1.5,
	-- Structural cast reach, not live-tunable -- same exclusion as
	-- GroundQueryCastDistance. Widened 3.5 -> 6 on 2026-09-18 (real playtest
	-- bug: `CanEnter[WallRun]`'s SERVER-side evaluation kept rejecting a
	-- claim the client had already legitimately earned -- confirmed via
	-- `WALL_TRAVERSAL_DEBUG_LOGGING` to be a genuine geometry miss, not a
	-- stale-cache issue, since `TraversalClaims.OnClaim` already re-probes fresh
	-- immediately before evaluating the claim). Root cause: Roblox's own
	-- replication cadence for a fast-moving, client-owned part is inherently
	-- lower than the physics/render rate -- the server's view of the
	-- player's position always lags by some amount no server-side "query
	-- fresher" fix can outrun, and at WallRunSpeed's real tuned value that
	-- lag alone can exceed a few studs even with zero network latency.
	-- Widening this is safe, not a reopened false-positive hole, because the
	-- cast distance was only ever the THIRD line of defense against
	-- accidentally stealing a DoubleJump press -- `WallRunMinEntrySpeed` and
	-- `WallRunEntryDotThreshold` both still have to ALSO pass simultaneously,
	-- and a player merely double-jumping near a wall isn't also moving fast
	-- AND aimed along that wall's tangent by coincidence.
	WallRunSideCastDistance = 6,
	-- Flatness gate: a side-cast hit only counts as a wall if its normal's
	-- dot with world-up is at or below this.
	WallDetectMaxUpDot = 0.3,
	-- QueryWallRun's own throttle, same dt-accumulator idiom as
	-- SlideGroundRaycastThrottleSeconds.
	WallRunQueryThrottleSeconds = 0.1,
	-- Claim-buffering window (2026-09-19 playtest bug): a "WallRun"/"WallLeap"
	-- claim can arrive while the server's OWN mirrored state hasn't caught up
	-- yet to support it -- e.g. the player left the ground and reached the
	-- wall in one fast, continuous gesture (a double jump chained straight
	-- into a wall run), and the claim lands before Roblox has replicated
	-- enough of the resulting position/CFrame change for `Probes.UpdateWallRunQuery`
	-- to see the wall, or even before the Humanoid state change that flips
	-- `context.grounded` has replicated. Same root cause `WallRunSideCastDistance`'s
	-- own widening (above) already diagnosed -- lag on a client-owned part
	-- that no single "query fresher at claim time" fix can fully outrun --
	-- just arriving from the timing side instead of the distance side. Rather
	-- than drop the claim after one failed attempt, it's buffered for this
	-- long and retried every Heartbeat off progressively fresher server state
	-- (`TraversalClaims.RetryBuffered`) -- the exact "input buffering" idiom
	-- every jump-adjacent game already uses for "pressed a frame early".
	-- Buffering changes nothing about what's LEGAL (every retry re-runs the
	-- identical `CanEnter`/topology check against the server's own state),
	-- only how many ticks it keeps checking for it. Short on purpose -- long
	-- enough to absorb real replication lag, not long enough to let a stale
	-- gesture "come true" against wall geometry the player has since moved
	-- well past.
	WallRunClaimBufferSeconds = 0.25,
	-- CanEnter[WallRun]'s momentum gate (docs/MovementSystem.md §4.5) -- no wall run from a
	-- standstill jump.
	WallRunMinEntrySpeed = 10,
	-- CanEnter[WallRun]'s alignment gate (docs/MovementSystem.md §4.5), a dot-product
	-- threshold against the signed wall tangent, applied to both move input and
	-- facing (no backwards or sideways wall runs) -- same "comfortably admits
	-- real WASD angles" idiom as SprintForwardDeadzone.
	WallRunEntryDotThreshold = 0.5,
	-- Locked horizontal speed while running (docs/MovementSystem.md §4.5) -- kept at/under
	-- SprintSpeed on purpose so the still-pending server validation (§6) can't
	-- false-positive against Airborne's own speed-sanity ceiling in the
	-- meantime (docs/MovementSystem.md §8).
	WallRunSpeed = 35,
	-- Controlled vertical sink while running -- the "gravity-defying" tuning
	-- knob, not zero (a hover) and not full gravity.
	WallRunSinkSpeed = 6,
	-- Target perpendicular distance from the wall surface (docs/MovementSystem.md §4.5's
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
	-- WallLeap launch vector (docs/MovementSystem.md §4.5, redesigned 2026-09-18): flat
	-- momentum burst added on top of whatever horizontal speed you actually
	-- have at leap time, along that same direction -- a kick, not a
	-- retention-scaled curve.
	WallLeapBurstForce = 75,
	-- Fixed lateral push-away-from-wall magnitude.
	WallLeapPushForce = 75,
	-- Fixed vertical arc magnitude -- a flat constant, not a decaying
	-- impulse like DoubleJump's.
	WallLeapUpwardForce = 100,

	-- WallCling/WallBoost (docs/MovementSystem.md §4.6) -- static cling, then a
	-- single free upward boost. Starting-point values, not measured -- retune
	-- in Studio once the mechanic is playtested (same "Fast & fluid, not yet
	-- tuned" status as the original speed/jump tiers).
	--
	-- Hard time cap on a single cling -- no Qi drain in v1 (locked design).
	WallClingMaxDuration = 2.5,
	-- Blockcast sweep distance (docs/MovementSystem.md §4.6: any near-vertical
	-- wall, no tag/attribute required).
	WallClingDistance = 3,
	-- Sized for R6: HumanoidRootPart sits ~3 studs above the feet, so a
	-- 4-stud-tall box centered on it spans ~1-5 studs above the feet -- a real
	-- body-height span, not a point probe, so thin slivers/corners don't
	-- register as clingable.
	WallClingCastSize = Vector3.new(2, 4, 0.2),
	-- Look direction must be within this many degrees of head-on to the wall
	-- (locked design) -- what actually separates a cling entry from a wall-run
	-- entry (side-on).
	WallClingMaxFacingAngleDegrees = 35,
	-- Flatness gate for a clingable surface, dot of the hit normal with world
	-- up -- a DIFFERENT threshold from WallRun's own WallDetectMaxUpDot (0.3)
	-- on purpose: cling is a stricter "near-vertical" gate (~15 degrees off
	-- vertical) than wall run's side-cast flatness check, since an overhang a
	-- wall-run side-cast would reject anyway should also never be clingable.
	WallClingMaxNormalY = 0.26,
	-- Delta-time accumulator interval for the ongoing wall-still-there recheck
	-- while holding (ARCHITECTURE.md §6 forbids a raw per-tick cast).
	WallClingRecheckInterval = 0.1,
	-- Move-input-along-away-from-wall magnitude that counts as a deliberate
	-- drop (locked design: S/pull-away drops to Airborne).
	WallClingDropInputThreshold = 0.5,
	-- Re-grab lockout after a timeout peel-off (locked design).
	WallClingTimeoutLockout = 0.75,
	-- Re-grab lockout after a deliberate drop (locked design).
	WallClingDropLockout = 0.3,
	-- Cooldown before a fresh cling is allowed after a boost (locked design:
	-- one boost per cling, re-cling allowed after a short cooldown).
	WallClingPostBoostCooldown = 0.25,
	-- No horizontal drift while clinging -- any non-zero value needs a
	-- measured, documented cause (docs/ARCHITECTURE.md §9); this is not a
	-- server tolerance, it's the mechanic's own design (static cling, no
	-- steered climbing).
	WallClingSpeedCeiling = 0,
	-- One-shot away-from-wall push on a voluntary Drop exit (Phase 6 exploit
	-- audit, 2026-09-19) -- structural/anti-cheat plumbing, same category as
	-- WallClingDistance/WallClingCastSize above, not a feel dial. The server
	-- has no signal that a Drop happened other than its OWN castClingWall
	-- probe going nil (docs/MovementSystem.md §7) -- a real geometry
	-- fact for Timeout/WallLost, but not for a voluntary release: with no
	-- push, a player who tapped the drop input once and let go of everything
	-- could keep falling straight past the same wall, still within the
	-- probe's reach, leaving the server's mirror stuck in WallCling (0 speed
	-- ceiling) for up to WallClingMaxDuration and rejecting a legitimate
	-- re-cling on a nearby wall in the meantime. This makes the underlying
	-- geometry actually change so the existing probe resolves quickly,
	-- rather than depending on the player continuing to hold input after
	-- the drop.
	WallClingDropSeparationSpeed = 10,

	-- Instant upward impulse (locked design: free, instant, then back to
	-- Airborne) -- ~36.7 studs of rise at default gravity (120^2 / (2 * 196.2),
	-- see TraversalMath.BallisticRise); recompute if gravity is customized.
	WallBoostUpwardForce = 120,
	-- Small push away from the wall so the character doesn't snag on friction
	-- while rising -- set to 0 if it feels wrong in playtest.
	WallBoostSeparationSpeed = 12,
	-- Short window, not a control lock -- gives the animation time to play and
	-- defines the window the server mirrors (docs/MovementSystem.md §4.6).
	WallBoostStateDuration = 0.6,
	-- How long a cling must last before F can boost out of it (designer
	-- request 2026-09-24): latching on and boosting on the same beat skipped the
	-- cling entirely. Checked by the shared `CanEnter[WallBoost]`, timed on each
	-- side from that side's own cling entry.
	WallBoostMinClingSeconds = 0.6,

	-- Vault (docs/MovementSystem.md §4.8, docs/VaultMechanic.md): a mantle
	-- assist for a lip you almost cleared. Starting-point values derived from
	-- that goal and Sorcery's reference, not measured.
	--
	-- Structural (SpatialQueries.QueryLedge), not live-tunable: the server's
	-- mantle and rise bounds are built from them.
	-- Forward reach of the ledge casts; matches WallClingDistance, so the
	-- mantle never carries the character far sideways.
	VaultReach = 3,
	-- The ledge top must sit this high above the feet (knee height)...
	VaultMinLedgeHeight = 1.5,
	-- ...and no higher than this (just above the head). With
	-- VaultMantleClearance, the most the mantle can lift the character.
	VaultMaxLedgeHeight = 6,
	-- Flatness gate for the wall face, same value as WallClingMaxNormalY.
	VaultMaxNormalUpDot = 0.26,
	-- How far past the wall face the top probe (and the snap) lands.
	VaultTopInset = 1.25,
	-- The top must continue at least this far past the inset, so rails and
	-- thin walls don't count.
	VaultMinTopDepth = 1.5,
	-- ...and be within this height of the first top hit to count as one surface.
	VaultTopDepthTolerance = 0.5,
	-- A standable top (about 45 degrees at most).
	VaultMinTopNormalY = 0.7,
	-- Clear space above the top: the R6 rig's standing height.
	VaultHeadroom = 5,
	-- The mantle carries the feet this far above the top before crossing onto
	-- it, so they clear the lip and the Humanoid doesn't read the top as floor
	-- mid-mantle. Part of the server's rise bound, so not tunable.
	VaultMantleClearance = 0.5,
	-- During WallBoost the vault fires on its own (designer, 2026-09-25). A
	-- boost rises through the 4.5-stud height window in a few hundredths of a
	-- second, so the probe interval is derived from the rise speed to land at
	-- least this many probes inside the window (TraversalMath.VaultAutoProbeInterval).
	VaultAutoProbeSamplesPerWindow = 2,

	-- Feel (live-tunable). Sorcery's launch: 15 forward along the camera, 35 up
	-- (~3.1 studs of rise at default gravity), plus part of the entry momentum.
	VaultForwardSpeed = 70,
	VaultUpwardSpeed = 50,
	VaultHorizontalMomentumKeep = 0.4,
	-- Sorcery adds |vy| / 3, so a fast fall lifts you higher; capped here so
	-- the server's ceiling has a finite bound. 35 + 20 = JumpPower: a vault
	-- never out-launches a plain jump.
	VaultVerticalMomentumKeep = 1 / 3,
	VaultMaxMomentumUpward = 20,
	-- The whole Vault state, mantle then launch, before handing to Airborne:
	-- the Vault clip's length (designer, 2026-09-25).
	VaultDurationSeconds = 0.32,
	-- The longest the mantle takes: up the wall face, then across onto the top
	-- (replaced a one-frame snap, 2026-09-25 playtest: "you just snap"). An
	-- entry already rising faster mantles at its own speed instead
	-- (TraversalMath.VaultMantleDuration). The launch fires when it ends.
	-- Starting point, not measured.
	VaultMantleSeconds = 0.2,
	-- Head-on gate, same as WallClingMaxFacingAngleDegrees.
	VaultMaxFacingAngleDegrees = 35,
	-- Server-owned cooldown between vaults (Sorcery: 0.5 s).
	VaultCooldownSeconds = 0.5,
	-- No DoubleJump this soon after a vault (Sorcery's 0.25 s block).
	VaultDoubleJumpBlockSeconds = 0.25,
}

return MovementConstants
