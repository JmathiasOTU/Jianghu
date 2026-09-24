--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)
local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
local LandingResolution = require(ReplicatedStorage.Shared.Movement.LandingResolution)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)
local ViolationTracker = require(ReplicatedStorage.Shared.Util.ViolationTracker)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)
local VerticalAllowanceGranted = require(script.Parent.Parent.Events.VerticalAllowanceGranted)
local MovementViolation = require(script.Parent.Parent.Events.MovementViolation)
local MovementTuningState = require(script.Parent.Parent.State.MovementTuningState)
local NoclipState = require(script.Parent.Parent.State.NoclipState)
local DebugOverlayState = require(script.Parent.Parent.State.DebugOverlayState)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants

-- Symbol -> the plain string literal Network.MovementDebugState's payload needs
-- (Zap enums are string unions, not Symbols) -- see
-- Shared/FSM/MovementStateNames.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- client's own DEBUG_STATE_NAMES in Movement/init.luau).
local DEBUG_STATE_NAMES = MovementStateNames.DebugNames

-- Grounded-family states (docs/MovementSystem.md §4.4 rework) -- same "which states
-- count as grounded" question `session.peakHeight`'s seed/clear edge (below,
-- in `createSession`'s `fsm.changed` handler) needs answered server-side. See
-- Shared/FSM/MovementStateGroups.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- client's own GROUNDED_STATES in Movement/init.luau).
local GROUNDED_STATES = MovementStateGroups.Grounded

-- One flight for JUMP_LAUNCH_CAPTURE: where it left the ground, which mirror
-- state it left from, and the highest point it reached.
type JumpCapture = {
	from: string,
	takeoffY: number,
	takeoffAt: number,
	peakY: number,
	peakAt: number,
}

type PlayerSession = {
	-- Owns the FSM and every connection for this one character life (audit
	-- M-023); destroyed exactly once by `destroySession`, never reused.
	_trove: Trove.Trove,
	player: Player,
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	rateLimiter: RateLimiter.RateLimiter,
	-- Separate budget for the level claims (CrouchDown/CrouchUp, audit M-006;
	-- CameraLocked/CameraUnlocked, M-020) so Run/Sprint claims and their
	-- resyncs can never starve them.
	levelRateLimiter: RateLimiter.RateLimiter,
	-- Shift Lock/first-person, from the client's level claims (audit M-020).
	cameraLocked: boolean,
	runEnteredAt: number?,
	-- Horizontal speed window (audit M-002): the position/time the current
	-- window opened at, plus a distance budget accumulated EVERY Heartbeat at
	-- whatever cap applied during that Heartbeat. Transitions never reset the
	-- window, so a window straddling several states is judged against exactly
	-- the caps that were in force, and no state change can discard evidence.
	speedCheckPosition: Vector3,
	speedCheckAt: number,
	speedBudget: number,
	speedBudgetAt: number,
	-- The full effective cap (tier + any traversal allowance) in force right
	-- before the most recent transition, for the landing-momentum grace --
	-- recorded before that transition's own bookkeeping clears allowances.
	previousCap: number,
	-- Server-owned ground truth (audit M-004): does the R6 leg footprint sit on
	-- real collidable geometry right now (`SpatialQueries.QuerySupport`),
	-- refreshed once per Heartbeat before anything reads it. `supportedSince`
	-- is when the current stretch of "supported but labelled airborne" began.
	supported: boolean,
	supportedSince: number?,
	-- Horizontal speed of whatever the character stands on (audit M-014),
	-- credited to the speed budget on top of the character's own cap, and the
	-- floor's upward speed, which a jump off it inherits. Only what the server
	-- can vouch for (`trustedFloorVelocity`, re-audit N-003).
	floorSpeed: number,
	floorRiseSpeed: number,
	-- The most horizontal speed this character's own validation allowed on
	-- the last Heartbeat (cap plus its own floor credit). Another player
	-- standing on this character is credited at most this much (N-003).
	carrySpeed: number,
	-- Vertical ceiling (audit M-001): the highest Y this character can
	-- legitimately reach from here, derived only from server-known impulses
	-- (JumpPower, accepted DoubleJump/WallLeap/WallBoost/WallRun claims, and
	-- `VerticalAllowanceGranted`). `verticalExcessSince` is when the character
	-- first went above it without a claim catching up yet.
	verticalCeilingY: number,
	-- The latest moment anything that raised `verticalCeilingY` can still be
	-- carrying the character upward (re-audit N-002). After it, an unsupported
	-- character must be falling from the ceiling at least as fast as gravity
	-- (`TraversalMath.DescentCeiling`), unless the server has it on a wall or
	-- ladder, which holds this at "now".
	verticalApexAt: number,
	-- Capture only (2026-09-24 slide-jump false positives): where and when
	-- the ceiling was last anchored to the ground, and when/by how much a
	-- claim last raised it, so a violation line says which one was stale.
	verticalAnchorY: number,
	verticalAnchorAt: number,
	verticalRaisedAt: number?,
	verticalRaisedBy: number,
	-- A faster-than-JumpPower launch the mirror has seen start but whose
	-- takeoff the position stream may not show yet (SlideJump: the Humanoid
	-- label reaches the server ahead of the position). Anchors use it until
	-- the character actually leaves the ground; cleared on takeoff or landing.
	groundLaunchSpeed: number?,
	-- A ceiling raise accepted while the position stream still showed the
	-- character on the ground (claims, like the Humanoid label, lead the
	-- positions by ~0.15-0.2 s, so a DoubleJump pressed straight after a hop
	-- lands here). Ground anchors re-apply it until the character lifts off,
	-- for up to `claimLagSeconds` after it was accepted, instead of wiping it.
	groundRaise: { rise: number, apexAt: number, at: number }?,
	-- JUMP_LAUNCH_CAPTURE: the flight in progress since the last anchor.
	jumpCapture: JumpCapture?,
	verticalExcessSince: number?,
	verticalCheckAt: number,
	-- Where the character stood when the server entered HardLanding (audit
	-- M-010), so a jump out of the lock can be told apart from the floor
	-- giving way, and snapped back.
	hardLandingLockPosition: Vector3?,
	-- Landing-momentum grace (docs/MovementSystem.md §8, added 2026-09-14): the state
	-- this session was in immediately before its most recent transition, and
	-- when that transition happened -- generic over which transition, never
	-- keyed to "landed from Airborne" specifically. See `effectiveMaxSpeed`.
	previousState: MovementState?,
	lastTransitionAt: number,
	-- The one signal in this whole system with no natural replicated
	-- equivalent (docs/MovementSystem.md §4.2) -- set/cleared by the "CrouchDown"/
	-- "CrouchUp" claims, never derived. Every resulting FSM consequence
	-- (CrouchIdle/CrouchWalk/Slide entry and exit, crouched landing) is then
	-- mirrored passively off this flag by `mirrorPassiveTransitions`, the same
	-- way Idle<->Walk already is off `moveIntent`.
	crouchHeld: boolean,
	-- DoubleJump per-life flag (docs/MovementSystem.md §5/§8) -- mirrors the
	-- client's own flag 1:1: set on an accepted "DoubleJump" claim, reset the
	-- instant this session's mirror lands (same "Airborne -> grounded" edge
	-- `mirrorPassiveTransitions` already detects for the crouched-landing
	-- branch).
	doubleJumpUsed: boolean,
	-- Whether the support probe has seen the character off the ground since
	-- its double jump was used. The next real touchdown after that refreshes
	-- the double jump even if the mirror never lands (2026-09-24 capture: on a
	-- quick hop the Humanoid label, which leads the positions by ~0.15-0.2 s,
	-- has already switched to Jumping by the time the positions show the
	-- ground, so "label grounded AND supported" never holds and every
	-- following DoubleJump claim was rejected). Needing the lift-off first
	-- keeps a double jump pressed at takeoff, while the positions still show
	-- the ground just below, from refreshing itself.
	doubleJumpLeftGround: boolean,
	-- Crouch-lock (SlideJump landing fix) -- mirrors the client's own
	-- `crouchSuppressed` 1:1: armed the instant this session's mirror enters
	-- SlideJump, cleared on an accepted "CrouchUp" claim (the server's only
	-- source for the real key-up edge, same as `crouchHeld` itself). Masked
	-- into `context.crouchHeld` by `buildContext` below so the server's own
	-- passive-transition/landing logic independently arrives at the same
	-- "don't auto-recrouch after a slide jump" decision the client does,
	-- never trusting the client's own masked value.
	crouchSuppressed: boolean,
	-- Landing-resume fix -- mirrors the client's own `preAirborneLocomotion`
	-- 1:1: Run/Sprint if that's the tier this session's mirror was in the
	-- instant it left the ground, nil otherwise. Set in
	-- `mirrorPassiveTransitions`'s own "not grounded -> Airborne" branch
	-- (off `current`, the state about to be left, same source the client
	-- reads via `previous`), cleared the instant a landing resolves.
	preAirborneLocomotion: MovementState?,
	-- HardLanding fall-height tracking (docs/MovementSystem.md §4.4 rework) -- mirrors
	-- the client's own `peakHeight` 1:1, off this session's OWN
	-- `rootPart.Position.Y` (server-trusted, never anything the client
	-- asserts, docs/ARCHITECTURE.md §3): the peak height reached since this
	-- session's mirror last left the ground, nil while grounded. Grown every
	-- Heartbeat (`updatePeakHeight`, called before `mirrorPassiveTransitions`
	-- for the same same-frame-race reason as the client's own Heartbeat
	-- ordering comment), seeded/cleared in `createSession`'s `fsm.changed`
	-- handler.
	peakHeight: number?,
	-- HardLanding movement lock (docs/MovementSystem.md §4.4 rework) -- mirrors the
	-- client's own `HardLandingState`'s `lockedUntil`: this server's own
	-- `os.clock()` deadline, set the instant this session's mirror enters
	-- HardLanding, read by `mirrorPassiveTransitions`'s own HardLanding branch
	-- to decide when to resolve back out. The lock is enforced two ways: the
	-- HardLanding horizontal cap (`maxSpeedForState`) and the jump-escape
	-- check in `mirrorPassiveTransitions` against `hardLandingLockPosition`.
	hardLandingLockUntil: number?,
	-- Entry snapshot for DoubleJump's resimulation (docs/MovementSystem.md §8), reused as-is for
	-- WallRun's own entry timestamp (docs/MovementSystem.md §8.4 -- only one traversal move is ever
	-- active at a time, so one generic "when did I enter this move" field covers both) -- this
	-- server's OWN `os.clock()` the instant it accepted the claim, never anything the client sends.
	-- `mirrorPassiveTransitions` measures DoubleJump's own duration and WallRun's
	-- `WallRunMaxDurationSeconds` from it.
	traversalEntryAt: number?,
	-- WallRun's own side-cast probe, server side (docs/MovementSystem.md §4.5/§8.4) -- the
	-- SAME `SpatialQueries.QueryWallRun` pure function the client calls,
	-- never anything the client reports about wall position/normal. Updated
	-- every Heartbeat this session isn't grounded (`updateWallRunQuery`),
	-- independent of its current mirrored state -- needed both for
	-- `CanEnter[WallRun]`'s legality check at claim time and for
	-- `mirrorPassiveTransitions`'s sustain check while already in WallRun.
	wallRunQuery: SpatialQueries.WallRunQueryResult?,
	wallRunQueryAt: number,
	-- WallRun's locked entry normal (docs/MovementSystem.md §8.4) -- the server's OWN
	-- `wallRunQuery.normal` at the instant the claim was accepted, stored
	-- once and never re-read live, same "locked at Entry" rule the client's
	-- own `WallRunState` follows. Compared against the LIVE `wallRunQuery`
	-- every Heartbeat (`mirrorPassiveTransitions`) to detect a corner/curve
	-- exceeding `WallRunMaxNormalDeviationDegrees`.
	wallRunEntryNormal: Vector3?,
	-- The physical wall part itself (docs/MovementSystem.md §4.6/§5), same
	-- lazy-anchor timing as `wallRunEntryNormal` above (set on the SAME first
	-- post-entry `mirrorPassiveTransitions` probe, never a claim-time forced
	-- one, for the identical rotation-lag reason). Snapshotted into
	-- `lastWallLeapWall` the instant a WallLeap launch is accepted, so the
	-- server knows which wall to block re-clinging onto.
	wallRunEntryInstance: BasePart?,
	-- Claim-buffering deadlines (2026-09-19 playtest fix, see
	-- `WallRunClaimBufferSeconds`'s own comment for the full root-cause
	-- reasoning) -- set the instant a "WallRun"/"WallLeap" claim is rejected
	-- for a reason that might just be replication catching up (still
	-- airborne / still wall-running, respectively), cleared the instant the
	-- buffered retry succeeds, is abandoned, or expires. `retryBufferedTraversalClaims`
	-- is the only reader; `onClaimTraversalMove` is the only writer.
	pendingWallRunClaimUntil: number?,
	pendingWallLeapClaimUntil: number?,
	-- Sprint's own claim-buffering deadline (2026-09-21 "flagged switching
	-- Run->Sprint" investigation -- see `onRequestMovementTransition`'s Sprint
	-- rejection branch for the measured root cause). Set the instant a
	-- "Sprint" claim is rejected while this session is grounded and already
	-- mirrored into Run -- the ONLY way that combination fails
	-- `CanEnter[Sprint]` is the dwell check, and the rejection logging added
	-- during this investigation showed that miss landing within single
	-- milliseconds of the threshold almost every time (the client fires this
	-- claim the instant ITS OWN dwell clock crosses 3s; the server's
	-- independently-tracked, backdated clock needs to have ALSO crossed by
	-- the time this arrives, an inherent photo finish no amount of backdate
	-- tuning removes). Same `pendingWallRunClaimUntil` buffering idiom, reused
	-- rather than invented fresh: cleared the instant the buffered retry
	-- succeeds, is abandoned (no longer grounded/Run), or expires.
	-- `retryBufferedSprintClaim` is the only reader; `onRequestMovementTransition`
	-- is the only writer.
	pendingSprintClaimUntil: number?,
	-- Speed-sanity ceiling for a launch faster than the Airborne cap (WallLeap,
	-- playtest fix 2026-09-18; SlideJump, 2026-09-24). The launch speed
	-- doesn't decay on its own (Roblox applies no horizontal air drag), so the
	-- excess persists for the entire flight. An exact bound computed from
	-- server-known constants only (`TraversalMath.WallLeapMaxHorizontalSpeed`,
	-- audit M-003; `slideCeiling` -- never the client's replicated velocity),
	-- consulted by `effectiveMaxSpeed` until the flight ends: landing
	-- (server-verified), a wall, a ladder, water, or a vertical-ceiling
	-- correction. The descent check in `enforceVerticalCeiling` is what forces
	-- the flight to end (re-audit N-001): the character must fall once the
	-- arc tops out.
	airborneAllowedSpeed: number?,
	-- Set the first time the character is on real ground after the launch
	-- has topped out: the allowance lapses one landing grace later. The
	-- ceiling re-anchors on any support (see `enforceVerticalCeiling`), so
	-- without this a client that never reports landing could hop along the
	-- ground keeping a leap's speed forever.
	airborneAllowanceExpiresAt: number?,
	-- The fastest this slide can have started (2026-09-24 slide-jump
	-- rubber-band fix): the effective cap the server allowed just before the
	-- slide, scaled like the client's own entry and clamped to
	-- `slideCeiling`. `mirrorPassiveTransitions` times the slide's decay from it.
	slideEntrySpeed: number,
	-- Independent rate limit for ClaimTraversalMove (docs/MovementSystem.md §2)
	-- -- kept separate from `rateLimiter` (RequestMovementTransition's own),
	-- same orthogonal-cooldown principle Run/Sprint's limiter already
	-- established, just applied to the new event.
	traversalRateLimiter: RateLimiter.RateLimiter,
	-- Slide's own ground-normal cache (docs/MovementSystem.md §8/§4) --
	-- the server's own copy of the same throttled-raycast pattern
	-- SlideState.Update runs client-side, off `SpatialQueries.QueryGround`
	-- (the SAME pure function, never a second hand-synced geometry read). Only
	-- ever populated while this session is mirrored into Slide/SlideJump;
	-- `updateSlideGroundQuery` clears it the instant it isn't, so a stale
	-- normal from a slide that ended moments ago can never leak into
	-- `maxSpeedForState`'s cap for an unrelated state.
	slideGroundQuery: SpatialQueries.GroundQueryResult?,
	slideGroundQueryAt: number,
	-- WallCling's own probe (docs/MovementSystem.md §4.6/§8.4) -- the SAME
	-- `SpatialQueries.castClingWall` pure function the client calls, refreshed
	-- every Heartbeat while airborne (`updateWallClingQuery`, throttled off
	-- `WallClingRecheckInterval`, same cadence the client's own sustain-check
	-- uses) AND force-refreshed at claim time, same two-call-site pattern
	-- `wallRunQuery`/`updateWallRunQuery` already established. Consulted by
	-- `mirrorPassiveTransitions`'s own WallCling branch as its independent
	-- "is the wall still really there" check -- deliberately added even
	-- though the plan's own §11.3 argued the speed ceiling alone was enough:
	-- `enforceSpeedSanity` only ever measures HORIZONTAL (X/Z) delta, so a
	-- player who drops and falls STRAIGHT DOWN would never trip it, leaving
	-- the mirror stuck in WallCling (blocking a legitimate re-cling attempt
	-- via `next == self.current` in StateMachine:CanTransition) for up to the
	-- full `WallClingMaxDuration` -- the same class of mirror-desync bug
	-- WallRun's own sustain check exists to prevent, so it gets the same fix.
	wallClingQuery: SpatialQueries.ClingWallHit?,
	wallClingQueryAt: number,
	-- Server-owned re-grab lockout (docs/MovementSystem.md §4.6/§8.4) --
	-- the ONLY authoritative copy (docs/ARCHITECTURE.md §3); the client's own
	-- `WallClingState.lockoutUntil` is prediction only. Set by this session's
	-- OWN force-exit bookkeeping (`mirrorPassiveTransitions`'s WallCling
	-- branch), never anything the client claims.
	wallClingLockoutUntil: number?,
	-- Per-cling flag mirroring the client's own `boostUsedThisCling` 1:1 --
	-- false on every accepted WallCling claim, true the instant a WallBoost
	-- claim is accepted; `CanEnter[WallBoost]` reads it via `buildContext`.
	wallClingBoostUsed: boolean,
	-- Wall-leap memory, server side (docs/MovementSystem.md §4.6/§5) -- the
	-- server's OWN copy of `wallRunEntryInstance` at the instant a WallLeap
	-- launch was accepted, never anything the client asserts. Cleared on
	-- landing, same edge `peakHeight`/`airborneAllowedSpeed` already clear on.
	lastWallLeapWall: BasePart?,
	-- WallBoost's own launch timestamp (docs/MovementSystem.md §8.4/§8.2)
	-- -- a DEDICATED field, not a reuse of the generic `traversalEntryAt`
	-- (unlike WallCling's own duration check, which does reuse it): the boost
	-- envelope has to keep being enforced for a while AFTER the mirror has
	-- already returned to Airborne (`effectiveMaxSpeed`), the same
	-- "outlives the state itself" lifetime `airborneAllowedSpeed` already
	-- has, so it needs the identical dedicated-field treatment rather than a
	-- value something else might overwrite mid-flight. Cleared on landing.
	wallBoostStartedAt: number?,
	-- Claim-buffering deadline (playtest bug 2026-09-19: "jump toward a wall
	-- from outside cling range, cross into range mid-air, press Space -- the
	-- server rejects it every time") -- the SAME root cause
	-- `WallRunClaimBufferSeconds` was already added to fix for WallRun: the
	-- server's own replicated position/CFrame always lags the client's real
	-- one by some amount no query-fresher fix can outrun, so a claim thrown
	-- the instant the client crosses into range can land before the server's
	-- OWN `wallClingQuery` (position-dependent) has replicated far enough to
	-- agree. Reuses `WallRunClaimBufferSeconds` rather than a second,
	-- unmeasured constant -- same underlying replication-lag phenomenon, no
	-- reason to assume it needs a different window. Set the instant a
	-- "WallCling" claim is rejected while still airborne, cleared the instant
	-- the buffered retry succeeds, is abandoned, or expires.
	-- `retryBufferedTraversalClaims` is the only reader; `onClaimTraversalMove`
	-- is the only writer.
	pendingWallClingClaimUntil: number?,
	-- When the current cling began on the client, as far as the server can
	-- tell: its own accept time, moved back by however long the claim sat in
	-- the claim buffer. Times `WallBoostMinClingSeconds`.
	wallClingEnteredAt: number?,
	-- A WallBoost claim that reached the server a hair before its own cling
	-- clock reached `WallBoostMinClingSeconds`. The cling and boost claims
	-- travel the same reliable stream, so the two clocks differ only by
	-- jitter, but players mash F, so the boundary is hit constantly. Same
	-- photo-finish fix as `pendingSprintClaimUntil`: retried every Heartbeat
	-- against the real `CanEnter` until it passes or the buffer closes.
	pendingWallBoostClaimUntil: number?,
	-- A DoubleJump claim that arrived before the position stream showed the
	-- touchdown that refreshed it (2026-09-24 capture: hopping against a wall
	-- and mashing Space). Retried every Heartbeat for
	-- `WallRunClaimBufferSeconds`, the measured claim/position ordering window.
	pendingDoubleJumpClaimUntil: number?,
}

-- Rate limit for RequestMovementTransition, independent of the FSM's own legality
-- check -- see docs/ARCHITECTURE.md §5 and Shared/Util/RateLimiter.luau. A
-- network-layer concern, not gameplay tuning, so it lives here rather than in
-- MovementConstants.
local TRANSITION_CLAIMS_PER_SECOND = 5

-- Level claims (crouch, audit M-006; camera lock, M-020): edges plus one 1/s
-- resync per level. A drop is self-healing since the client resends each
-- current level every second, so this only bounds spam, never correctness.
local LEVEL_CLAIMS_PER_SECOND = 6

-- Rate limit for ClaimTraversalMove, independent of RequestMovementTransition's
-- own limiter above (docs/MovementSystem.md §2) -- same reasoning, separate
-- counter so a burst against one event can never eat into the other's budget.
local TRAVERSAL_CLAIMS_PER_SECOND = 5

-- Absorbs standing-still jitter during HardLanding's WalkSpeed=0 lock without
-- tolerating a real WASD movement attempt.
local HARD_LANDING_RESIDUAL_SPEED_TOLERANCE = 6

-- Measurement capture for the vertical ceiling (audit M-001, ARCHITECTURE §9):
-- prints how far above the ceiling a character went and for how long, every
-- time it happens. The ceiling ships with ZERO tolerance; if honest play
-- produces excesses, this capture is what sizes a documented fix -- never a
-- guessed slack constant.
local VERTICAL_CEILING_DEBUG_LOGGING = false

-- Measurement capture for the ceiling's launch speeds (2026-09-24): honest
-- single-press slide jumps were caught leaving the ground at ~62 studs/s
-- against JumpPower 55. On every landing this prints the flight's peak above
-- its takeoff, the time to reach it, the launch speed that implies
-- (sqrt(2 g peak)) and the mirror state it left from, so standing, running
-- and slide jumps can be told apart before any constant is changed. Studio
-- playtests only; turn it off once the numbers are recorded.
local JUMP_LAUNCH_CAPTURE = false

-- Measurement capture for SpeedToleranceMultiplier (audit M-007/M-015/M-016,
-- ARCHITECTURE §9): every closed speed window records how far the character
-- really moved as a fraction of the budget it was allowed (before the
-- tolerance multiplier). Honest play's p99.9 of that ratio IS the measured
-- tolerance. Windows with zero budget (WallCling) report their raw drift in
-- studs instead, which is what sizes the cling's "no drift" definition.
-- Studio playtests only; the sample list is capped.
local SPEED_RATIO_CAPTURE = false
local SPEED_RATIO_REPORT_EVERY = 200
local SPEED_RATIO_MAX_SAMPLES = 20000
local speedRatioSamples: { number } = {}
local speedRatioSinceReport = 0
local zeroBudgetDriftMax = 0

-- Temporary instrumentation for the 2026-09-13 Sprint-rubber-banding
-- investigation (docs/MovementSystem.md §8) -- prints real numbers instead of guessing
-- at a tolerance. Flip on for a playtest, off for normal play; left in (not
-- deleted) since Stage 2's WallRun/etc. validation will want the same kind of
-- capture again.
local SPEED_SANITY_DEBUG_LOGGING = false

-- Diagnostic capture for the 2026-09-18 "WallLeap boost gets erased" bug --
-- same pattern as the other *_DEBUG_LOGGING flags above. Prints why a
-- WallRun/WallLeap claim was rejected, or why `mirrorPassiveTransitions`
-- force-exits WallRun. Re-enabled (still 2026-09-18) after the SpeedSanity
-- rubber-band came back post-retune (WallRunSpeed 26->35,
-- WallLeapBurstForce/PushForce 14/16->75/75) -- need to confirm whether the
-- claim is being rejected again (same root cause as before) versus something
-- new, rather than guessing at a second patch on top of the first.
local WALL_TRAVERSAL_DEBUG_LOGGING = false

-- Sized from a real 2026-09-14 playtest capture (docs/MovementSystem.md §8), not a
-- guess: every landing sample showed the FIRST `enforceSpeedSanity` check after
-- an Airborne->Walk transition firing at elapsed ~0.50-0.517s (just the normal
-- check cadence) and never a second correction after it -- the whole residual-
-- momentum transient decays back under the new cap within that first window,
-- it just needs grace that actually covers it. One `SpeedCheckIntervalSeconds`
-- of grace (the original placeholder) was already expired BY the time that
-- first check ran (elapsed >= grace), which is why it measured zero
-- protection. Two intervals comfortably covers the observed ~0.5-0.517s first
-- check with margin, without over-granting a second window nothing in the
-- capture ever showed a need for.
local LANDING_MOMENTUM_GRACE_SECONDS = 2 * MovementConstants.SpeedCheckIntervalSeconds

-- The fastest a slide or slide jump ever goes before slope amplification:
-- SlideState.Enter and SlideJumpState.Enter both clamp to it client-side.
local function slideCeiling(constants: EffectiveMovementConstants): number
	return constants.SprintSpeed * constants.SlideEntrySpeedMultiplier
end

local MovementValidationService = {}

local sessions: { [Player]: PlayerSession } = {}
local speedViolations = ViolationTracker.new()
-- One tracker per kind: the debug overlay's payload is shaped around the
-- horizontal check's distance/budget/elapsed, and each kind keeps its own
-- count for the moderation event.
local violationTrackers: { [MovementViolation.Kind]: ViolationTracker.ViolationTracker } = {
	Speed = speedViolations,
	VerticalCeiling = ViolationTracker.new(),
	HardLandingEscape = ViolationTracker.new(),
}

-- Every correction reports through here (audit M-008): recorded, then
-- published on MovementViolation for a future moderation system. Policy
-- (flag, kick) deliberately lives with that subscriber, not in this service.
--
-- Every kind prints in Studio playtests: the debug overlay's history only
-- shows Speed, so a vertical or HardLanding snap was otherwise invisible. In
-- a live server a cheater could flood the log at will (audit M-025), so there
-- the record goes to the trackers and the event only.
local function reportViolation(
	session: PlayerSession,
	kind: MovementViolation.Kind,
	detail: { [string]: number }
)
	local violation = violationTrackers[kind]:Record(session.player, detail)
	if SPEED_SANITY_DEBUG_LOGGING or RunService:IsStudio() then
		local fields = {}
		for key, value in pairs(detail) do
			table.insert(fields, string.format("%s=%.3f", key, value))
		end
		table.sort(fields)
		print(
			string.format(
				"[MovementViolation] %s %s state=%s %s",
				session.player.Name,
				kind,
				tostring(session.fsm.current),
				table.concat(fields, " ")
			)
		)
	end
	MovementViolation:Fire(session.player, kind, detail, violation.count)
end

local function recordSpeedRatio(flatDistance: number, budget: number)
	if budget <= 0 then
		zeroBudgetDriftMax = math.max(zeroBudgetDriftMax, flatDistance)
		return
	end
	if #speedRatioSamples < SPEED_RATIO_MAX_SAMPLES then
		table.insert(speedRatioSamples, flatDistance / budget)
	end
	speedRatioSinceReport += 1
	if speedRatioSinceReport < SPEED_RATIO_REPORT_EVERY then
		return
	end
	speedRatioSinceReport = 0

	local sorted = table.clone(speedRatioSamples)
	table.sort(sorted)
	local function percentile(fraction: number): number
		return sorted[math.clamp(math.ceil(fraction * #sorted), 1, #sorted)]
	end
	print(
		string.format(
			"[SpeedRatio] n=%d p50=%.3f p99=%.3f p99.9=%.3f max=%.3f zeroBudgetDriftMax=%.3f studs",
			#sorted,
			percentile(0.5),
			percentile(0.99),
			percentile(0.999),
			sorted[#sorted],
			zeroBudgetDriftMax
		)
	)
end

local function resetSpeedWindow(session: PlayerSession)
	local now = os.clock()
	session.speedCheckPosition = session.rootPart.Position
	session.speedCheckAt = now
	session.speedBudget = 0
	session.speedBudgetAt = now
end

-- Every server position correction lands here (audit M-008): moves the rig
-- (rotation kept) and kills its velocity, so a cheat snapped back doesn't just
-- resume at full speed the next frame, then restarts the speed window from
-- the corrected position.
local function correctToPosition(session: PlayerSession, position: Vector3)
	local rootPart = session.rootPart
	rootPart.CFrame = (rootPart.CFrame - rootPart.Position) + position
	rootPart.AssemblyLinearVelocity = Vector3.zero
	resetSpeedWindow(session)
end

local function isGrounded(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
end

-- How much of a floor's velocity the server can vouch for (re-audit N-003),
-- as (horizontal speed, upward speed). Anchored geometry and server-owned
-- physics parts are moved by the server, so their velocity is real. Another
-- player's character is moved by that player's client: its horizontal speed
-- is believed up to what that player is itself allowed to carry, its vertical
-- speed not at all. Any other unanchored part is simulated by some client --
-- possibly this one, driving the part it stands on -- so it earns nothing.
local function trustedFloorVelocity(floor: BasePart, velocity: Vector3): (number, number)
	local flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local rise = math.max(velocity.Y, 0)
	if floor:IsGrounded() then
		return flat, rise
	end

	local character = floor:FindFirstAncestorOfClass("Model")
	local rider = if character then Players:GetPlayerFromCharacter(character :: Model) else nil
	if rider then
		local riderSession = sessions[rider]
		return if riderSession then math.min(flat, riderSession.carrySpeed) else 0, 0
	end

	local ok, owner = pcall(function()
		return floor:GetNetworkOwner()
	end)
	if ok and owner == nil then
		return flat, rise
	end
	return 0, 0
end

-- Refreshed once per Heartbeat (and forced at claim time) before anything
-- reads `session.supported`, so every consumer in one Heartbeat agrees.
local function updateSupport(session: PlayerSession)
	local hit = SpatialQueries.QuerySupport(session.rootPart, session.humanoid.Parent :: Instance)
	local supported = hit ~= nil
	session.supported = supported
	if hit then
		session.floorSpeed, session.floorRiseSpeed =
			trustedFloorVelocity(hit.floor, hit.floorVelocity)
	else
		session.floorSpeed, session.floorRiseSpeed = 0, 0
	end
	-- Start of the current stretch where the character is on real ground but
	-- its Humanoid label says it isn't -- reset by either one ending.
	if not supported or isGrounded(session.humanoid:GetState()) then
		session.supportedSince = nil
	elseif not session.supportedSince then
		session.supportedSince = os.clock()
	end

	-- Touching down again after a double jump refreshes it (see
	-- `doubleJumpLeftGround`).
	if session.doubleJumpUsed then
		if not supported then
			session.doubleJumpLeftGround = true
		elseif session.doubleJumpLeftGround then
			session.doubleJumpUsed = false
		end
	end
end

-- How far the server's view of a move can trail the client's own (re-audit
-- N-002): one network leg (server-measured ping, never client-sent) plus the
-- measured claim buffer (`WallRunClaimBufferSeconds`), which already exists
-- because position replication and claims arrive in either order. Capped at
-- one speed window, so a lag-switching client can't stretch it further.
local function claimLagSeconds(session: PlayerSession): number
	local oneWay = math.max(session.player:GetNetworkPing(), 0) / 2
	return math.min(
		oneWay + MovementConstants.WallRunClaimBufferSeconds,
		MovementConstants.SpeedCheckIntervalSeconds
	)
end

-- `timeToApex`: how long after this accept the move can still be rising
-- (see `verticalApexAt`).
local function raiseVerticalCeiling(session: PlayerSession, rise: number, timeToApex: number)
	session.verticalCeilingY += math.max(rise, 0)
	session.verticalApexAt = math.max(session.verticalApexAt, os.clock() + timeToApex)
	session.verticalRaisedAt = os.clock()
	session.verticalRaisedBy += math.max(rise, 0)
	if session.supported then
		local now = os.clock()
		local pending = session.groundRaise
		session.groundRaise = {
			rise = (if pending then pending.rise else 0) + math.max(rise, 0),
			apexAt = math.max(if pending then pending.apexAt else 0, now + timeToApex),
			at = now,
		}
	end
end

-- The server's own answer to "is this character on the ground" (audit M-004).
-- A grounded Humanoid label only counts with real geometry under the feet, so
-- a client can't fake a landing mid-air to refresh DoubleJump or clear its
-- fall height. The reverse lie (reporting Freefall while standing, to keep an
-- airborne speed cap or a WallLeap allowance alive) ends once that mismatch
-- has lasted a full speed-check window -- an honest takeoff or landing only
-- spends a few frames within `GroundQueryCastDistance` of the floor while
-- labelled airborne.
local function isSessionGrounded(session: PlayerSession): boolean
	if not session.supported then
		return false
	end
	if isGrounded(session.humanoid:GetState()) then
		return true
	end
	local mismatchSince = session.supportedSince
	return mismatchSince ~= nil
		and os.clock() - mismatchSince >= MovementConstants.SpeedCheckIntervalSeconds
end

-- The server never sees raw WASD key state (that's client-only), so it can't
-- literally reconstruct "is W held" the way InputController does. Instead this
-- mirrors the same forward/backward/strafe *classification* SprintState.Update
-- relies on, geometrically: forward/backward from facing's dot with MoveDirection
-- past a deadzone, strafeLeft/strafeRight from the sign of the analogous cross
-- product (same convention as LocomotionAnimator.resolveDirectionBucket -- positive
-- means Right). Both inputs (rootPart.CFrame, humanoid.MoveDirection) are written
-- by the network-owning client (audit M-004/M-027), so this only classifies
-- intent for the mirror's tier choices -- every cap it can unlock is still
-- enforced against real displacement by `enforceSpeedSanity`.
--
-- Forward/backward use a deadzone (this session's effective
-- SprintForwardDeadzone, docs/MovementSystem.md §10 -- MovementConstants' shipped
-- 0.5 unless a developer is live-tuning it) rather than a bare `> 0`/`< 0`
-- zero-crossing (hardened 2026-09-13): real WASD input only ever produces a
-- facing/MoveDirection angle of 0/45/90+ degrees, so the shipped deadzone
-- (comfortably below cos 45° ≈ 0.707) never affects legitimate diagonal
-- Sprint-holding -- it only closes off a spoofed `MoveDirection` sitting at a
-- razor-thin positive angle (e.g. 89°) that used to satisfy `> 0` and dodge
-- the Sprint->Run demotion while moving almost entirely sideways.
local function classifyMoveIntent(
	facing: Vector3,
	moveDirection: Vector3,
	deadzone: number
): (boolean, boolean, boolean, boolean)
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	local flatMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flatFacing.Magnitude == 0 or flatMove.Magnitude == 0 then
		return false, false, false, false
	end
	flatFacing = flatFacing.Unit
	flatMove = flatMove.Unit

	local forwardComponent = flatFacing:Dot(flatMove)
	local rightComponent = flatMove:Cross(flatFacing).Y

	return forwardComponent > deadzone,
		forwardComponent < -deadzone,
		rightComponent < 0,
		rightComponent > 0
end

-- `constants` is this session's EFFECTIVE tuning (docs/MovementSystem.md §10) --
-- read fresh from MovementTuningState on every call rather than cached on the
-- session, so a live override change is picked up on the very next Heartbeat
-- with no extra invalidation bookkeeping. StateRules.CanEnter (shared with the
-- client) reads SprintThresholdSeconds off this same field, never off
-- MovementConstants directly, so the two can never disagree about the number
-- actually in effect for this player.
local function buildContext(session: PlayerSession): MovementContext
	local constants = MovementTuningState.GetEffective(session.player)

	local runDuration = if session.fsm.current == MovementStates.Run and session.runEnteredAt
		then os.clock() - (session.runEnteredAt :: number)
		else nil

	local humanoidState = session.humanoid:GetState()
	local moveDirection = session.humanoid.MoveDirection
	local facing = session.rootPart.CFrame.LookVector
	local forward, backward, strafeLeft, strafeRight =
		classifyMoveIntent(facing, moveDirection, constants.SprintForwardDeadzone)

	return {
		moveIntent = {
			direction = moveDirection,
			forward = forward,
			backward = backward,
			strafeLeft = strafeLeft,
			strafeRight = strafeRight,
		},
		grounded = isSessionGrounded(session),
		jumping = humanoidState == Enum.HumanoidStateType.Jumping,
		crouchHeld = session.crouchHeld and not session.crouchSuppressed,
		doubleJumpUsed = session.doubleJumpUsed,
		runDuration = runDuration,
		preAirborneLocomotion = session.preAirborneLocomotion,
		fallHeight = if session.peakHeight
			then session.peakHeight - session.rootPart.Position.Y
			else nil,
		horizontalVelocity = Vector3.new(
			session.rootPart.AssemblyLinearVelocity.X,
			0,
			session.rootPart.AssemblyLinearVelocity.Z
		),
		-- The server's OWN throttled probe (docs/MovementSystem.md §4.5/§8.4, `updateWallRunQuery`
		-- below) -- never anything the client reports.
		wallRunQuery = session.wallRunQuery,
		-- The server's OWN throttled probe (docs/MovementSystem.md §4.6/§8.4,
		-- `updateWallClingQuery` below) -- never anything the client reports.
		wallClingQuery = session.wallClingQuery,
		-- Real replicated `rootPart.CFrame.LookVector` -- reuses the same
		-- `facing` value already computed above for `classifyMoveIntent`,
		-- never a second read.
		facingDirection = facing,
		wallClingLockoutUntil = session.wallClingLockoutUntil,
		wallClingBoostUsed = session.wallClingBoostUsed,
		wallClingElapsed = if session.fsm.current == MovementStates.WallCling
				and session.wallClingEnteredAt
			then os.clock() - session.wallClingEnteredAt
			else nil,
		lastWallLeapWall = session.lastWallLeapWall,
		-- Still an open design decision (docs/MovementSystem.md §13/§2) --
		-- "always available" until a real Qinggong/stamina resource exists,
		-- same placeholder the client uses.
		qinggong = math.huge,
		-- Landing-resume fix, hardened 2026-09-18 (see MovementTypes.luau's
		-- own field comment). From the client's CameraLocked/CameraUnlocked
		-- level claims (audit M-020), not `Humanoid.AutoRotate`: the client
		-- writes that property locally and it never replicated, so the server
		-- always read "unlocked". Lying "unlocked" only selects the lenient
		-- landing path this used to take for everyone; the speed cap still
		-- applies regardless.
		cameraLocked = session.cameraLocked,
		constants = constants,
	}
end

-- Idle/Walk/Airborne need no remote (Humanoid state already replicates), so the
-- mirror follows them passively here. Run/Sprint are only ever *entered* via the
-- explicit claim below -- this never attempts either as a target, so an unclaimed
-- client can never end up mirrored as Run/Sprint no matter what MoveDirection says.
-- Sprint's demotion back to Run IS handled here, on the server's own initiative
-- (see docs/MovementSystem.md §8) -- it doesn't wait for the client to re-claim Run.
local function mirrorPassiveTransitions(session: PlayerSession)
	local context = buildContext(session)
	local current = session.fsm.current

	-- Slide -> SlideJump -> Airborne (docs/MovementSystem.md §4.2): reactive off the
	-- same already-replicated Humanoid state Airborne's own entry already
	-- reads (`context.jumping`) -- no claim needed, same reasoning as
	-- Airborne itself. Checked before every other branch below since
	-- `context.grounded` has ALREADY flipped false by the time `jumping`
	-- reads true (both come from the same single `Humanoid:GetState()`), so
	-- the generic "not grounded -> Airborne" branch further down would
	-- otherwise catch this first and skip the boost entirely.
	if current == MovementStates.Slide and context.jumping then
		if session.fsm:RequestTransition(MovementStates.SlideJump, context) then
			-- Crouch-lock (SlideJump landing fix): armed the instant this
			-- session's mirror enters SlideJump, same edge the client's own
			-- `crouchSuppressed` arms on -- see the PlayerSession field comment.
			session.crouchSuppressed = true
			-- SlideJumpState.Enter launches at up to `slideCeiling`, above the
			-- Airborne cap, and nothing slows it in the air, so the flight
			-- keeps that allowance until it ends (2026-09-24 fix: it used to
			-- get only the 1s landing grace, which a long jump outlasts).
			-- Set before the hand-off so the landing grace snapshot sees it.
			session.airborneAllowedSpeed = slideCeiling(context.constants)
			session.airborneAllowanceExpiresAt = nil
			-- SlideJumpState launches upward at SlideJumpUpwardSpeed, faster
			-- than the Humanoid's JumpPower. Still on the ground as far as the
			-- position stream shows: the anchors up to takeoff use it. Already
			-- off the ground: raise the ceiling from that takeoff instead.
			local launchSpeed = MovementConstants.SlideJumpUpwardSpeed
			if session.supported then
				session.groundLaunchSpeed = launchSpeed
			else
				local gravity = Workspace.Gravity
				local jumpSpeed = context.constants.JumpPower + session.floorRiseSpeed
				raiseVerticalCeiling(
					session,
					TraversalMath.BallisticRise(launchSpeed, gravity)
						- TraversalMath.BallisticRise(jumpSpeed, gravity),
					math.max(
						session.verticalAnchorAt
							+ TraversalMath.TimeToApex(launchSpeed, gravity)
							- os.clock(),
						0
					)
				)
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	if current == MovementStates.Airborne then
		if context.grounded then
			-- Landing while Ctrl is held goes to the crouch-variant instead of
			-- Idle/Walk (docs/MovementSystem.md §4.2) -- a single-tick decision, same
			-- as AirborneState.Update's own client-side landing logic.
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				-- DoubleJump reset (docs/MovementSystem.md §5): mirrors the
				-- client's own reset on the identical "landed" edge.
				session.doubleJumpUsed = false
				-- Landing-resume fix: consumed the instant a landing actually
				-- resolves, same edge as the doubleJumpUsed reset just above.
				session.preAirborneLocomotion = nil
			end
		end
		return
	end

	-- DoubleJump hands itself back to Airborne once its own decay curve
	-- finishes (docs/MovementSystem.md §5/§8), on the server's own initiative,
	-- off its own entry-snapshot timestamp, never anything the client asserts
	-- about when its impulse "should" end. Checked BEFORE the generic
	-- "not grounded -> Airborne" fallback below, which would otherwise fire
	-- every single Heartbeat while DoubleJump is active (it's airborne by
	-- definition) and immediately evict the mirror out of DoubleJump the
	-- instant the claim was accepted.
	--
	-- Landing mid-impulse is its OWN branch, not folded into "-> Airborne":
	-- `Airborne.CanEnter` requires `not grounded`, already false by the
	-- instant `context.grounded` reads true here, so that transition would
	-- simply be rejected and leave the mirror stuck in DoubleJump -- resolves
	-- straight to the real grounded target instead, same fix as the client's
	-- own DoubleJumpState.Update.
	if current == MovementStates.DoubleJump then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				-- Landing-resume fix: same consume-on-landing edge as the
				-- Airborne branch above -- `preAirborneLocomotion` survives the
				-- Airborne -> DoubleJump hop untouched (see where it's set,
				-- below), so this mid-impulse landing still needs to clear it.
				session.preAirborneLocomotion = nil
			end
			return
		end

		local elapsed = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
		if elapsed >= context.constants.DoubleJumpDecayDurationSeconds then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallRun's anti-exploit backbone (docs/MovementSystem.md §8.4)
	-- -- runs every server Heartbeat this session is mirrored into WallRun,
	-- off the session's OWN `wallRunQuery`/entry snapshot, never anything the
	-- client claims or reports. A client that stops sending packets, or lies
	-- about still being on a wall, gets force-mirrored back to Airborne the
	-- instant the server's own shapecast says the wall is gone, the corner
	-- budget is exceeded, or the duration cap hits -- independent of what the
	-- client-side FSM thinks is happening. Landing mid-run is its own branch
	-- first, same "resolve straight to the real grounded target, don't fall
	-- through to a rejected -> Airborne attempt" shape DoubleJump's own
	-- branch above already established.
	if current == MovementStates.WallRun then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local query = session.wallRunQuery

		-- Lazy-anchor the corner-deviation reference (2026-09-19 playtest fix:
		-- a real force-exit was observed ~0.12s after a legitimately accepted
		-- entry, `angleExceeded=true` on the very first post-entry query).
		-- `onClaimTraversalMove` locks `wallRunEntryNormal` off a FORCED probe
		-- taken at the exact claim instant -- but that probe reads
		-- `session.rootPart.CFrame`, and CFrame (rotation), not just position,
		-- replicates from the client with its own lag independent of
		-- `WallRunSideCastDistance`'s already-documented position lag. A
		-- player's rig is still finishing its turn to face along the wall
		-- tangent at the instant the claim lands, so the FIRST cast can read a
		-- glancing, not-yet-settled normal; the very next throttled query
		-- (~`WallRunQueryThrottleSeconds` later, once rotation has caught up)
		-- then reads the REAL normal, which can easily be > the corner budget
		-- away from that first noisy sample -- a false corner, not a real one.
		-- Anchoring instead off the first query `mirrorPassiveTransitions`
		-- itself observes (this Heartbeat loop's own natural throttled
		-- cadence, not a claim-time forced probe) gives rotation a beat to
		-- settle before anything gets compared against it. This doesn't
		-- relax the anti-exploit check -- the SAME angle/duration budget still
		-- applies from here on -- it only fixes which sample the budget is
		-- measured against.
		if not session.wallRunEntryNormal then
			if query then
				session.wallRunEntryNormal = query.normal
				-- Same lazy-anchor timing as the normal above (docs/MovementSystem.md §4.6/§5) --
				-- captured here, not at claim time, so `lastWallLeapWall` (set off this when a leap
				-- is accepted) agrees with whichever wall the corner-deviation check itself is
				-- actually anchored to.
				session.wallRunEntryInstance = query.instance
			end
			return
		end

		local angleExceeded = query
			and TraversalMath.AngleBetween(query.normal, session.wallRunEntryNormal :: Vector3)
				> context.constants.WallRunMaxNormalDeviationDegrees
		local durationExceeded = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
			>= context.constants.WallRunMaxDurationSeconds

		if not query or angleExceeded or durationExceeded then
			if WALL_TRAVERSAL_DEBUG_LOGGING then
				print(
					string.format(
						"[WallTraversal] %s WallRun force-exit: query=%s entryNormal=%s angleExceeded=%s durationExceeded=%s elapsed=%.2f",
						session.player.Name,
						tostring(query ~= nil),
						tostring(session.wallRunEntryNormal ~= nil),
						tostring(angleExceeded == true),
						tostring(durationExceeded),
						os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
					)
				)
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallCling's anti-exploit backbone (docs/MovementSystem.md §8.4)
	-- -- duration cap (reuses the generic `traversalEntryAt`, same as
	-- DoubleJump/WallRun, since this check only ever matters while still
	-- mirrored into WallCling) plus an independent wall-presence recheck off
	-- this session's OWN throttled probe (`updateWallClingQuery`). The plan's
	-- own §11.3 argued the speed ceiling alone (WallClingSpeedCeiling = 0)
	-- was enough and skipped a periodic re-cast entirely -- but
	-- `enforceSpeedSanity` only ever measures HORIZONTAL (X/Z) delta, so a
	-- player who legitimately drops and falls straight down would never trip
	-- it, leaving the mirror stuck in WallCling (via `next == self.current`
	-- in StateMachine:CanTransition) for up to the full duration cap and
	-- rejecting a legitimate re-cling in the meantime -- the identical
	-- mirror-desync failure mode WallRun's own sustain check (just above)
	-- already exists to prevent. Landing mid-cling is its own branch first,
	-- same "resolve straight to the real grounded target" shape every other
	-- airborne-family state here already establishes.
	if current == MovementStates.WallCling then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local durationExceeded = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
			>= context.constants.WallClingMaxDuration

		if not session.wallClingQuery or durationExceeded then
			-- Only Timeout applies a lockout here (docs/MovementSystem.md §4.6's exit-reason table)
			-- -- a server-detected WallLost leaves `wallClingLockoutUntil` untouched, same "none"
			-- the client's own WallLost branch already applies.
			if durationExceeded then
				session.wallClingLockoutUntil = os.clock()
					+ context.constants.WallClingTimeoutLockout
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallBoost (docs/MovementSystem.md §8.4): a short, fixed window off
	-- its OWN dedicated `wallBoostStartedAt` (not the generic
	-- `traversalEntryAt` -- see that field's own PlayerSession comment for
	-- why), hands back to Airborne once it elapses. No further legality to
	-- check while inside it -- `effectiveMaxSpeed`'s own envelope formula is
	-- what actually keeps this window honest, not a corner/wall recheck.
	if current == MovementStates.WallBoost then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local startedAt = session.wallBoostStartedAt or session.lastTransitionAt
		if os.clock() - startedAt >= context.constants.WallBoostStateDuration then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- HardLanding (docs/MovementSystem.md §4.4 rework): mirrors `HardLandingState.
	-- Update` client-side exactly -- losing the ground mid-lock is involuntary
	-- and takes priority over the lock timer (nothing left to lock the player
	-- TO); otherwise holds until this session's own `hardLandingLockUntil`
	-- (set server-side, off this session's own effective tuning, on the
	-- `fsm.changed` edge into HardLanding -- never anything the client
	-- claims), then re-resolves the SAME landing decision Airborne/DoubleJump
	-- use. `context.fallHeight` is already nil by this point (cleared the
	-- instant HardLanding was entered), so this always resolves to an
	-- ordinary grounded target, never back into HardLanding again.
	--
	-- Server-enforced (audit M-010, designer answer 2026-09-24): while the
	-- lock runs, only the server's OWN support probe can end it -- the
	-- client's Humanoid label is ignored. Losing support after rising more
	-- than the probe's reach above the lock position can only be a jump (a
	-- vanishing floor drops the character, never lifts it), so it is a
	-- violation and the character is put back where the lock began.
	if current == MovementStates.HardLanding then
		local lockUntil = session.hardLandingLockUntil
		local lockPosition = session.hardLandingLockPosition
		if lockUntil and lockPosition and os.clock() < lockUntil then
			if session.supported then
				return
			end
			local rise = session.rootPart.Position.Y - lockPosition.Y
			if
				rise
				> MovementConstants.GroundQueryCastDistance
					- MovementConstants.RigRootHeightAboveFeet
			then
				-- The client's lock started when IT landed; the server only
				-- sees that landing once the position and Humanoid state have
				-- replicated, so its own lock ends later by up to that delay.
				-- A jump in the lock's last `claimLagSeconds` is the client's
				-- lock ending first, not an escape (2026-09-24 playtest:
				-- jumping the moment a hard landing ended snapped players back).
				local remaining = lockUntil - os.clock()
				if remaining <= claimLagSeconds(session) then
					session.fsm:RequestTransition(MovementStates.Airborne, context)
					return
				end
				reportViolation(
					session,
					"HardLandingEscape",
					{ rise = rise, lockRemaining = remaining }
				)
				correctToPosition(session, lockPosition)
				return
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
			return
		end
		if not context.grounded then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
			return
		end
		session.fsm:RequestTransition(LandingResolution.Resolve(context), context)
		return
	end

	if not context.grounded then
		-- Landing-resume fix: `current` is whatever grounded state this
		-- session's mirror is about to leave -- the same "previous" the
		-- client's own fsm.changed handler reads, just sourced before the
		-- transition instead of from the edge's own callback args.
		if current == MovementStates.Run or current == MovementStates.Sprint then
			session.preAirborneLocomotion = current
		end
		session.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if current == MovementStates.Slide then
		-- Decay estimate (docs/MovementSystem.md §4.2): the server never tracks
		-- Slide's exact real velocity -- its speed cap is the flat
		-- `slideCeiling` (see `maxSpeedForState`), not a simulated curve --
		-- this only estimates WHEN the client's own decay reaches CrouchSpeed,
		-- timed from the fastest entry the client could have had
		-- (`slideEntrySpeed`). It used to use the bare Run/Sprint tier, which
		-- left out SlideEntrySpeedMultiplier: the mirror left Slide up to 0.5s
		-- before the client did, and a slide jump in that gap reached the
		-- server as a plain jump capped at SprintSpeed (2026-09-24 fix). A
		-- slower real entry ends the client's slide first; the mirror follows
		-- once its own estimate runs out, which only ever keeps the higher
		-- Slide cap a little longer.
		local entrySpeed = session.slideEntrySpeed
		local elapsed = os.clock() - session.lastTransitionAt
		local decayedSpeed = math.max(
			context.constants.CrouchSpeed,
			entrySpeed - context.constants.SlideDecayRate * elapsed
		)
		if decayedSpeed <= context.constants.CrouchSpeed then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.CrouchWalk
					else MovementStates.CrouchIdle,
				context
			)
		end
		return
	end

	if current == MovementStates.CrouchIdle then
		if not context.crouchHeld then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.Walk
					else MovementStates.Idle,
				context
			)
		elseif StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.CrouchWalk, context)
		end
		return
	end

	if current == MovementStates.CrouchWalk then
		if not context.crouchHeld then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.Walk
					else MovementStates.Idle,
				context
			)
		elseif not StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.CrouchIdle, context)
		end
		return
	end

	-- From here on, `current` is one of Idle/Walk/Run/Sprint -- Crouch/Slide
	-- takes priority over the ordinary family the instant Ctrl is held,
	-- exactly the same priority every client state module's own Update
	-- already gives it (docs/MovementSystem.md §4.2). CrouchWalk is gated behind
	-- CrouchIdle (mirrors IdleState/WalkState client-side), so Idle/Walk
	-- always land in CrouchIdle first, even with move input already held --
	-- the CrouchIdle branch above re-checks input the very next tick.
	if context.crouchHeld then
		if current == MovementStates.Run or current == MovementStates.Sprint then
			session.fsm:RequestTransition(MovementStates.Slide, context)
			return
		end
		session.fsm:RequestTransition(MovementStates.CrouchIdle, context)
		return
	end

	if current == MovementStates.Idle then
		if StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.Walk, context)
		end
	elseif not StateRules.HasMoveInput(context) then
		-- Walk, Run, or Sprint with no input left: drop straight to Idle.
		session.fsm:RequestTransition(MovementStates.Idle, context)
	elseif
		current == MovementStates.Sprint
		and session.cameraLocked
		and not context.moveIntent.forward
	then
		-- Same demotion condition as SprintState.Update client-side (backpedal or
		-- pure strafe drops Sprint), enforced independently of whether a modified
		-- client ever sends the matching reclaim.
		--
		-- Gated on a locked camera (found during the 2026-09-13
		-- rubber-banding investigation): `classifyMoveIntent` approximates "is this
		-- forward" from `rootPart.CFrame.LookVector` vs. `MoveDirection`, but
		-- `FacingController`'s own fix (§4, also 2026-09-13) established that
		-- facing *deliberately* lags MoveDirection whenever `AutoRotate` is true
		-- (unlocked camera) -- Roblox's own ground controller turns the character
		-- to catch up rather than snapping. A player who simply looks around while
		-- holding forward, unlocked, can swing MoveDirection well ahead of facing
		-- for a few frames -- comfortably past this check's deadzone -- with zero
		-- backward/strafe input at all. That's not a desync to correct for, it's
		-- this proxy being the wrong signal in that mode: strafe-style facing
		-- decoupling (and with it, a meaningful "backpedal relative to facing")
		-- only applies while locked in the first place (see this doc's intro).
		-- The lock state comes from the client's CameraLocked/CameraUnlocked
		-- level claims (audit M-020): `AutoRotate`, which this used to read, is
		-- written client-side and never replicated, so this branch never ran.
		--
		-- This narrows, rather than removes, server enforcement while unlocked:
		-- the "no input at all -> Idle" branch above and `enforceSpeedSanity`'s
		-- speed cap both still apply unconditionally. The one residual gap is
		-- narrow and low-severity -- a modified client could hold Sprint's speed
		-- cap (not Run's) while moving backward, unlocked, without ever
		-- backpedal-demoting -- documented in docs/MovementSystem.md §8 rather than
		-- silently accepted.
		if session.fsm:RequestTransition(MovementStates.Run, context) then
			-- RunState.Enter resets the client's own dwell clock on every entry
			-- into Run, this demotion included -- without this reset, a client
			-- that never re-sends the "Run" claim (bug found 2026-09-13: a
			-- malicious one has no reason to) would keep the ORIGINAL
			-- runEnteredAt from before Sprint, so re-claiming "Sprint" a moment
			-- later would instantly pass the dwell check off stale elapsed time,
			-- instead of requiring a fresh 3-second Run streak like a legitimate
			-- client always does.
			session.runEnteredAt = os.clock()
		end
	end
end

-- HardLanding fall-height tracking, server side (docs/MovementSystem.md §4.4
-- rework) -- mirrors the client's own Heartbeat-ordering comment exactly:
-- grow-only, and MUST run before `mirrorPassiveTransitions` below in the
-- Heartbeat loop, for the identical same-frame-race reason. On the exact
-- landing Heartbeat, `context.grounded` has already flipped true by the time
-- `mirrorPassiveTransitions` reads it to make the landing decision -- if this
-- reset `session.peakHeight` off that same read, `fallHeight` would already
-- be ~0 by the time `LandingResolution.Resolve` consults it moments later in
-- the SAME frame. Resetting is left entirely to the `fsm.changed` handler in
-- `createSession`, which only fires (synchronously, inside
-- `mirrorPassiveTransitions`'s own `RequestTransition` call) AFTER the
-- landing decision has already consumed the real peak.
local function updatePeakHeight(session: PlayerSession)
	local peakHeight = session.peakHeight
	if not peakHeight then
		return
	end
	local y = session.rootPart.Position.Y
	-- Water breaks a fall (swimming in scope, 2026-09-24): without this, a
	-- dive into water followed by climbing out onto land resolved the whole
	-- drop as one fall and forced HardLanding. Mirrors the client exactly.
	if
		session.humanoid:GetState() == Enum.HumanoidStateType.Swimming
		and SpatialQueries.IsInWater(session.rootPart.Position)
	then
		session.peakHeight = y
		return
	end
	session.peakHeight = math.max(peakHeight, y)
end

-- Slide's own ground-normal probe, server side (docs/MovementSystem.md §8/§4) -- throttled the same
-- way the client's own SlideState.Update is, just off `os.clock()` deltas rather than a `dt`
-- accumulator, since this file's Heartbeat loop doesn't carry a `dt` of its own (every other
-- server-side duration here is already `os.clock()`-timestamp-based, e.g.
-- `speedCheckAt`/`lastTransitionAt`). Cleared to nil the instant this session isn't mirrored into
-- Slide/SlideJump, so a stale read can't outlive the state it was measured for.
local function updateSlideGroundQuery(session: PlayerSession, constants: EffectiveMovementConstants)
	local current = session.fsm.current
	if current ~= MovementStates.Slide and current ~= MovementStates.SlideJump then
		session.slideGroundQuery = nil
		return
	end

	local now = os.clock()
	if now - session.slideGroundQueryAt < constants.SlideGroundRaycastThrottleSeconds then
		return
	end
	session.slideGroundQueryAt = now
	session.slideGroundQuery =
		SpatialQueries.QueryGround(session.rootPart, session.humanoid.Parent :: Instance)
end

-- Server's own side-cast probe (docs/MovementSystem.md §4.5/§8.4).
-- `force` bypasses the throttle for claim-time legality checks, which need
-- real current geometry (§3), not a stale Heartbeat-cadence sample (§9).
local function updateWallRunQuery(session: PlayerSession, force: boolean?)
	if isSessionGrounded(session) then
		session.wallRunQuery = nil
		return
	end

	local now = os.clock()
	if
		not force
		and now - session.wallRunQueryAt < MovementConstants.WallRunQueryThrottleSeconds
	then
		return
	end
	session.wallRunQueryAt = now
	session.wallRunQuery =
		SpatialQueries.QueryWallRun(session.rootPart, session.humanoid.Parent :: Instance)
end

-- WallCling's own forward-cast probe, server side (docs/MovementSystem.md §4.6/§8.4) -- same
-- throttle-with-force-bypass shape as `updateWallRunQuery` above, off `WallClingRecheckInterval`
-- (the SAME non-tunable structural cadence the client's own sustain-check uses, kept fixed rather
-- than added to live tuning for the identical "server-only anti-cheat plumbing" reasoning
-- `WallRunQueryThrottleSeconds` already has). Continuous while airborne (not just while mirrored
-- into WallCling) so a claim evaluated the instant Space is pressed already has a fresh sample,
-- same reasoning `wallRunQuery` is kept continuously fresh rather than only probed on demand.
local function updateWallClingQuery(session: PlayerSession, force: boolean?)
	if isSessionGrounded(session) then
		session.wallClingQuery = nil
		return
	end

	local now = os.clock()
	if
		not force
		and now - session.wallClingQueryAt < MovementConstants.WallClingRecheckInterval
	then
		return
	end
	session.wallClingQueryAt = now
	session.wallClingQuery =
		SpatialQueries.castClingWall(session.rootPart, session.humanoid.Parent :: Instance)
end

-- Companion to the client's own slope-amplification read (SlideState.Update)
-- -- same `TraversalMath.SlideSlopeAmplification` function, fed the server's
-- own cached ground-normal and the session's replicated
-- `AssemblyLinearVelocity` direction. That velocity is client-written, but it
-- only picks a direction here: the amplification it can unlock is capped at
-- `SlideSlopeAmplificationCap` and needs a real server-probed slope.
local function slideSlopeAmplification(
	session: PlayerSession,
	constants: EffectiveMovementConstants
): number
	local query = session.slideGroundQuery
	if not query then
		return 0
	end

	local velocity = session.rootPart.AssemblyLinearVelocity
	local direction = Vector3.new(velocity.X, 0, velocity.Z)
	if direction.Magnitude == 0 then
		return 0
	end

	return TraversalMath.SlideSlopeAmplification(
		query.normal,
		direction.Unit,
		math.rad(constants.SlideSlopeAngleThresholdDegrees),
		math.rad(constants.SlideMaxWalkableSlopeDegrees),
		constants.SlideSlopeAmplificationCap
	)
end

-- WalkSpeed is the ground-truth cap Roblox's own Humanoid:Move() enforces for a
-- well-behaved client, but WalkSpeed itself is just a replicated property the
-- network-owning client (the player, for their own character) can set directly --
-- a classic speed-hack bypasses the FSM entirely and never calls
-- RequestMovementTransition at all, it just writes a bigger WalkSpeed straight onto
-- the Humanoid. So the cap checked here is keyed off the SERVER's own mirrored FSM
-- state, never `humanoid.WalkSpeed` as reported -- that value can't be trusted at
-- all (docs/ARCHITECTURE.md §3). Airborne has no state of its own that sets speed
-- (`AirborneState.Enter` is a no-op, per `AirborneState.luau`) -- whatever tier was
-- active at takeoff carries into the jump -- so it's capped at the ceiling
-- (SprintSpeed) rather than guessing which tier the player jumped from.
-- Crouch/Slide additions (docs/MovementSystem.md §4.2): CrouchIdle/CrouchWalk cap at
-- CrouchSpeed, same "own dedicated tier" treatment as Walk/Run.
--
-- Slide/SlideJump cap became a FORMULA, not a flat tier (docs/MovementSystem.md §8, Phase 3):
-- `SprintSpeed * SlideEntrySpeedMultiplier` -- the SAME boosted ceiling
-- `SlideState.Enter`/`SlideJumpState.Enter` clamp to client-side (docs/MovementSystem.md §4.2,
-- 2026-09-15 entry-speed tuning pass; before that pass this was a bare `SprintSpeed`, same
-- reasoning as Airborne's existing ceiling) -- PLUS `slopeAmplification`, the same downhill top-up
-- `TraversalMath.SlideSlopeAmplification` grants the client, so a real slope-boosted slide doesn't
-- rubber-band against a cap that only ever assumed flat ground. `slopeAmplification` defaults to 0
-- for every call site that doesn't have a live ground read to pass.
local function maxSpeedForState(
	state: MovementState,
	constants: EffectiveMovementConstants,
	slopeAmplification: number?
): number
	if state == MovementStates.Run then
		return constants.RunSpeed
	elseif state == MovementStates.Slide or state == MovementStates.SlideJump then
		return slideCeiling(constants) + (slopeAmplification or 0)
	elseif
		state == MovementStates.Sprint
		or state == MovementStates.Airborne
		or state == MovementStates.DoubleJump
		or state == MovementStates.WallLeap
	then
		-- DoubleJump/WallLeap only ever apply a launch impulse -- horizontal
		-- speed otherwise carries through from whatever tier was active at
		-- takeoff, same "ceiling, not a guessed tier" reasoning Airborne
		-- already uses. Neither is ever actually the LIVE `session.fsm.current`
		-- for more than the one accepting Heartbeat (WallLeap hands straight
		-- back to Airborne in the same call, docs/MovementSystem.md §8.4) -- this branch only
		-- matters for the `previousCap` grace snapshot right after one of
		-- them; WallLeap's (and SlideJump's) real launch speed comes from
		-- `airborneAllowedSpeed`.
		return constants.SprintSpeed
	elseif state == MovementStates.WallRun then
		-- Live-capped at the mechanic's OWN tuned speed (docs/MovementSystem.md §8.4),
		-- deliberately NOT suspended like DoubleJump/WallLeap's one-shot
		-- impulses -- WallRun is sustained, so exempting the whole hold would
		-- let a modified client fly at any speed for as long as it claims
		-- WallRun. `enforceSpeedSanity` stays live throughout, just raised to
		-- this cap instead of Airborne's lower SprintSpeed ceiling.
		return constants.WallRunSpeed
	elseif state == MovementStates.WallCling then
		-- No horizontal drift while clinging (docs/MovementSystem.md §8.2)
		-- -- a fixed, non-tunable literal, not `constants.WallClingSpeedCeiling`
		-- (deliberately excluded from live tuning, docs/ARCHITECTURE.md §9's
		-- "no band-aid validation": any non-zero value needs a specific,
		-- measured, documented cause, not a knob a developer can nudge away a
		-- false flag with).
		return MovementConstants.WallClingSpeedCeiling
	elseif state == MovementStates.WallBoost then
		-- Same "one-shot impulse" shape as DoubleJump/WallLeap above: the
		-- boost's horizontal part (`WallBoostSeparationSpeed`) sits under this
		-- cap, and its vertical part is enforced by the vertical ceiling.
		return constants.SprintSpeed
	elseif state == MovementStates.CrouchIdle or state == MovementStates.CrouchWalk then
		return constants.CrouchSpeed
	elseif state == MovementStates.HardLanding then
		-- Not a literal 0 -- that made maxDistance always exactly 0, flagging
		-- even standing-still jitter every single check.
		return HARD_LANDING_RESIDUAL_SPEED_TOLERANCE
	end
	return constants.WalkSpeed
end

-- Landing-momentum grace (docs/MovementSystem.md §8, added 2026-09-14): distinct from
-- `createSession`'s existing per-transition baseline reset below, which only
-- ever fixed windows that straddled a transition boundary (mixing old- and
-- new-tier motion in one sample). This fixes a DIFFERENT case -- a window
-- entirely AFTER a transition, already in the new state, still measuring real
-- residual momentum: Humanoid's ground controller decelerates toward a lower
-- WalkSpeed target over a real, documented handful of frames rather than
-- snapping instantly, and that tail can genuinely exceed the new tier's cap for
-- a moment (most sharply landing from Sprint/Airborne down into Walk).
--
-- Keyed generically off "the cap decreased at the last transition," never off
-- "coming from Airborne" or "going to Walk" specifically -- `session.previousState`
-- is whatever state was active immediately before, so Stage 2's WallRun/
-- ClimbVault/LedgeGrab/Slide (all of which will exit into Airborne or Walk with
-- their own residual momentum) get this grace for free the moment their own cap
-- is taught to `maxSpeedForState`, with no separate copy of this fix needed.
local function capForState(
	session: PlayerSession,
	state: MovementState,
	constants: EffectiveMovementConstants
): number
	local currentCap =
		maxSpeedForState(state, constants, slideSlopeAmplification(session, constants))

	-- A fast launch's own computed ceiling (WallLeap, playtest fix 2026-09-18;
	-- SlideJump) -- takes over from the ordinary Airborne/SprintSpeed cap for
	-- as long as the flight lasts (see the field's own comment on
	-- `PlayerSession`). `math.max`, not an unconditional
	-- override -- never LOWERS the cap below whatever the state would allow.
	local allowance = session.airborneAllowedSpeed
	local expiresAt = session.airborneAllowanceExpiresAt
	if allowance and allowance > currentCap and not (expiresAt and os.clock() >= expiresAt) then
		currentCap = allowance
	end

	-- No WallBoost term (audit M-024): the boost's horizontal part is only
	-- `WallBoostSeparationSpeed`, already under every airborne cap; its
	-- vertical part is policed by the vertical ceiling instead.
	return currentCap
end

-- The cap `effectiveMaxSpeed` gives `state`, grace included, judged by the
-- bookkeeping of the transition that entered it.
local function effectiveCapFor(
	session: PlayerSession,
	state: MovementState,
	constants: EffectiveMovementConstants
): number
	local currentCap = capForState(session, state, constants)

	-- Skips the grace below -- it's sized for an ordinary landing's brief
	-- momentum tail, not a multi-second lock.
	if state == MovementStates.HardLanding then
		return currentCap
	end

	-- `previousCap` is the full effective cap in force right before the last
	-- transition (allowances included), so landing out of a WallLeap graces
	-- the leap's real speed rather than only the bare Airborne tier.
	local previousCap = session.previousCap
	if previousCap <= currentCap then
		-- The cap went up or stayed the same -- there's no residual-momentum
		-- tail to grace here, only ever downward transitions produce one.
		return currentCap
	end

	if os.clock() - session.lastTransitionAt < LANDING_MOMENTUM_GRACE_SECONDS then
		return previousCap
	end
	return currentCap
end

local function effectiveMaxSpeed(
	session: PlayerSession,
	constants: EffectiveMovementConstants
): number
	return effectiveCapFor(session, session.fsm.current, constants)
end

local function createSession(player: Player, humanoid: Humanoid, rootPart: BasePart): PlayerSession
	local trove = Trove.new()
	local fsm = trove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)
	local session: PlayerSession = {
		_trove = trove,
		player = player,
		humanoid = humanoid,
		rootPart = rootPart,
		fsm = fsm,
		rateLimiter = RateLimiter.new(TRANSITION_CLAIMS_PER_SECOND, 1),
		levelRateLimiter = RateLimiter.new(LEVEL_CLAIMS_PER_SECOND, 1),
		cameraLocked = false,
		runEnteredAt = nil,
		speedCheckPosition = rootPart.Position,
		speedCheckAt = os.clock(),
		speedBudget = 0,
		speedBudgetAt = os.clock(),
		previousCap = 0,
		supported = false,
		supportedSince = nil,
		floorSpeed = 0,
		floorRiseSpeed = 0,
		carrySpeed = 0,
		verticalCeilingY = rootPart.Position.Y + TraversalMath.BallisticRise(
			MovementTuningState.GetEffective(player).JumpPower,
			Workspace.Gravity
		),
		verticalApexAt = os.clock() + TraversalMath.TimeToApex(
			MovementTuningState.GetEffective(player).JumpPower,
			Workspace.Gravity
		),
		verticalAnchorY = rootPart.Position.Y,
		verticalAnchorAt = os.clock(),
		verticalRaisedAt = nil,
		verticalRaisedBy = 0,
		groundLaunchSpeed = nil,
		groundRaise = nil,
		jumpCapture = nil,
		verticalExcessSince = nil,
		verticalCheckAt = os.clock(),
		hardLandingLockPosition = nil,
		previousState = nil,
		lastTransitionAt = os.clock(),
		crouchHeld = false,
		doubleJumpUsed = false,
		doubleJumpLeftGround = false,
		crouchSuppressed = false,
		preAirborneLocomotion = nil,
		peakHeight = nil,
		hardLandingLockUntil = nil,
		traversalEntryAt = nil,
		traversalRateLimiter = RateLimiter.new(TRAVERSAL_CLAIMS_PER_SECOND, 1),
		slideGroundQuery = nil,
		slideGroundQueryAt = 0,
		wallRunQuery = nil,
		wallRunQueryAt = 0,
		wallRunEntryNormal = nil,
		wallRunEntryInstance = nil,
		airborneAllowedSpeed = nil,
		airborneAllowanceExpiresAt = nil,
		slideEntrySpeed = 0,
		pendingWallRunClaimUntil = nil,
		pendingWallLeapClaimUntil = nil,
		pendingSprintClaimUntil = nil,
		wallClingQuery = nil,
		wallClingQueryAt = 0,
		wallClingLockoutUntil = nil,
		wallClingBoostUsed = false,
		lastWallLeapWall = nil,
		wallBoostStartedAt = nil,
		pendingWallClingClaimUntil = nil,
		wallClingEnteredAt = nil,
		pendingWallBoostClaimUntil = nil,
		pendingDoubleJumpClaimUntil = nil,
	}

	-- The speed window is deliberately NOT reset here (audit M-002): it used to
	-- be, to keep a window from straddling two tiers, but that let any client
	-- that could force transitions (by toggling its own Humanoid state) discard
	-- every window before it was ever measured. `enforceSpeedSanity` now builds
	-- each window's budget per Heartbeat from whichever cap was live, so a
	-- straddling window is judged correctly without throwing evidence away.
	trove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		local now = os.clock()
		local constants = MovementTuningState.GetEffective(player)

		-- The client enters a slide at its real speed x SlideEntrySpeedMultiplier,
		-- clamped to `slideCeiling` (SlideState.Enter). The server's bound on
		-- that real speed is the effective cap it allowed in `previous`, grace
		-- included, so it's read before this handler moves the grace on.
		if next == MovementStates.Slide then
			session.slideEntrySpeed = math.min(
				effectiveCapFor(session, previous, constants),
				constants.SprintSpeed
			) * constants.SlideEntrySpeedMultiplier
		end

		-- Landing-momentum grace bookkeeping (see `effectiveMaxSpeed`) --
		-- records the full cap that applied in `previous`, BEFORE this
		-- handler's own landing bookkeeping below clears any allowance.
		session.previousCap = capForState(session, previous, constants)
		session.previousState = previous
		session.lastTransitionAt = now

		-- WallRun and WallCling both replace the character's velocity outright
		-- (full-force override), so a WallLeap allowance carried in from an
		-- earlier leap no longer describes anything physical -- and left in
		-- place it would lift WallCling's zero-drift cap to leap speed.
		if next == MovementStates.WallRun or next == MovementStates.WallCling then
			session.airborneAllowedSpeed = nil
		end

		-- Post-boost re-grab cooldown, server-owned (audit M-038): the client
		-- applies it on WallBoost's own Exit, so the server applies it on the
		-- same edge of its own mirror.
		if previous == MovementStates.WallBoost then
			session.wallClingLockoutUntil = now + constants.WallClingPostBoostCooldown
		end

		-- HardLanding fall-height bookkeeping (docs/MovementSystem.md §4.4 rework) --
		-- mirrors Movement/init.luau's own client-side edge exactly: seeded on
		-- the real takeoff edge (`next == Airborne`, excluding the Airborne <->
		-- DoubleJump hop so the peak survives it), cleared the instant a
		-- landing actually resolves.
		if next == MovementStates.Airborne then
			if
				previous ~= MovementStates.DoubleJump
				and previous ~= MovementStates.WallRun
				and previous ~= MovementStates.WallLeap
				and previous ~= MovementStates.WallCling
				and previous ~= MovementStates.WallBoost
			then
				session.peakHeight = rootPart.Position.Y
			end
		elseif GROUNDED_STATES[next] then
			session.peakHeight = nil
			session.groundLaunchSpeed = nil
			session.groundRaise = nil
			-- WallLeap ceiling bookkeeping (playtest fix 2026-09-18) -- cleared
			-- the instant this session actually lands, same edge as
			-- `peakHeight` just above, so an elevated post-leap speed
			-- allowance can never linger as a standing exploit once back on
			-- the ground.
			session.airborneAllowedSpeed = nil
			-- WallCling/WallBoost bookkeeping (docs/MovementSystem.md §4.6/
			-- §11.5), same landing edge as the two clears just above.
			session.lastWallLeapWall = nil
			session.wallBoostStartedAt = nil
		end

		-- HardLanding lock deadline (docs/MovementSystem.md §4.4 rework) -- mirrors
		-- the client's own `HardLandingState.Enter` timestamp exactly, off
		-- this session's own EFFECTIVE tuning (never a client-claimed
		-- duration) so `mirrorPassiveTransitions`'s own HardLanding branch
		-- knows exactly when the client-side lock is expected to release.
		if next == MovementStates.HardLanding then
			session.hardLandingLockUntil = now + constants.HardLandingDurationSeconds
			session.hardLandingLockPosition = rootPart.Position
		elseif previous == MovementStates.HardLanding then
			session.hardLandingLockPosition = nil
		end

		-- Passability (docs/MovementSystem.md §4.2): the SERVER's own copy, keyed off
		-- its own mirrored state -- never the client's. This is the
		-- authoritative copy every OTHER client's view of this character (and
		-- the server's own collision awareness) is built from; the owning
		-- client's identical, independent write in Movement/init.luau is only
		-- for that client's own local physics simulation feel.
		CollisionGroups.Apply(humanoid.Parent :: Model, next)

		if SPEED_SANITY_DEBUG_LOGGING then
			local previousCap = session.previousCap
			local newCap = capForState(session, next, constants)
			if previousCap > newCap then
				print(
					string.format(
						"[SpeedSanity] %s %s -> %s, cap %.1f -> %.1f, grace window started",
						player.Name,
						tostring(previous),
						tostring(next),
						previousCap,
						newCap
					)
				)
			end
		end
	end)

	-- Matches the client's own initial call in Movement/init.luau -- the FSM
	-- starts already in Idle, so no `changed` fires for it, and this session's
	-- CollisionGroup needs setting up front for the same reason.
	CollisionGroups.Apply(humanoid.Parent :: Model, MovementStates.Idle)
	trove:Add(CollisionGroups.Watch(humanoid.Parent :: Model))

	return session
end

-- Lightweight anti-noclip/speed-hack net (docs/MovementSystem.md §8): not a full
-- predict-validate-correct loop (no raycasts, no world geometry) -- Phase 1 has
-- nothing spatial to validate yet, just "did this player cover more ground than
-- their currently-mirrored tier allows." Sampled over a fixed interval rather than
-- every Heartbeat: per-frame `CFrame` replication from an owning client arrives in
-- bursts, not evenly, so a raw frame-to-frame delta would false-positive on normal
-- replication jitter long before it caught a real speed hack. Vertical (Y) motion
-- is policed separately by `enforceVerticalCeiling`.
--
-- The window's allowed distance is a budget accumulated every Heartbeat at the
-- cap live during that Heartbeat (audit M-002), so neither a transition nor a
-- one-shot "exemption" ever discards an unmeasured stretch of movement. The
-- old post-claim suspension window is gone for the same reason: 5 accepted
-- DoubleJump claims a second each suspending the check for 0.5s turned it off.
--
-- Exempted entirely while `NoclipState.IsActive` (docs/MovementSystem.md §10) -- the
-- scouting tool's whole point is to move faster than any tier's cap allows, so
-- without this exemption it would rubber-band the very thing it exists for.
-- Checked against the SERVER's own authorized record, never a client-reported
-- flag (docs/ARCHITECTURE.md §3) -- DevToolsService.luau is the only writer.
local function enforceSpeedSanity(session: PlayerSession, constants: EffectiveMovementConstants)
	if NoclipState.IsActive(session.player) then
		resetSpeedWindow(session)
		return
	end

	local now = os.clock()
	-- The floor's own speed rides on top of the character's cap (audit M-014,
	-- player-vs-player collision kept on): standing on a moving platform or
	-- another player's head carries you along. Only physics-driven motion the
	-- server can vouch for counts (`trustedFloorVelocity`) -- an anchored part
	-- moved by CFrame/tween reports zero.
	session.carrySpeed = effectiveMaxSpeed(session, constants) + session.floorSpeed
	session.speedBudget += session.carrySpeed * (now - session.speedBudgetAt)
	session.speedBudgetAt = now

	local elapsed = now - session.speedCheckAt
	if elapsed < MovementConstants.SpeedCheckIntervalSeconds then
		return
	end

	local position = session.rootPart.Position
	local previous = session.speedCheckPosition
	local flatDelta = Vector3.new(position.X - previous.X, 0, position.Z - previous.Z)
	local maxDistance = session.speedBudget * MovementConstants.SpeedToleranceMultiplier

	if SPEED_RATIO_CAPTURE then
		recordSpeedRatio(flatDelta.Magnitude, session.speedBudget)
	end

	if flatDelta.Magnitude > maxDistance then
		-- `reportViolation` prints it in Studio (docs/MovementSystem.md §10);
		-- ViolationTracker keeps a bounded history of the detail instead of
		-- only the running count, so broadcastDebugState can show the
		-- overlay's last few corrections, not just how many there have been.
		reportViolation(session, "Speed", {
			flatDelta = flatDelta.Magnitude,
			maxDistance = maxDistance,
			elapsed = elapsed,
		})

		-- Horizontal-only snap: Y is left to the vertical ceiling, and the
		-- horizontal velocity is killed so the cheat can't simply carry on
		-- (audit M-008).
		local rootPart = session.rootPart
		local corrected = Vector3.new(previous.X, position.Y, previous.Z)
		rootPart.CFrame = (rootPart.CFrame - position) + corrected
		rootPart.AssemblyLinearVelocity = Vector3.new(0, rootPart.AssemblyLinearVelocity.Y, 0)
	end

	resetSpeedWindow(session)
end

-- Vertical ceiling (audit M-001): the highest Y this character can legally
-- reach, built only from server-known impulses. Standing on real ground
-- re-anchors it to "here plus one Humanoid jump"; every accepted vertical move
-- raises it by that move's own maximum rise (`raiseVerticalCeiling`). Every
-- built-in launch REPLACES vertical velocity rather than adding to it, and the
-- character can't be above the old ceiling when it launches, so old ceiling +
-- rise is a true upper bound whatever the timing.
--
-- Descent (re-audit N-001/N-002): the ceiling is also a point in time. Each
-- launch records when it stops rising (`verticalApexAt`); after that an
-- unsupported character with nothing holding it up must be falling from the
-- ceiling at least as fast as gravity (`TraversalMath.DescentCeiling`), so it
-- can't hover or float down. This is also what ends a WallLeap speed
-- allowance: the leap's flight has to come down, and the landing clears it.
-- The ceiling re-anchors whenever the server's own support probe finds real
-- ground under the feet, whatever the Humanoid label says (2026-09-24
-- playtest capture): the label is client-written and reaches the server
-- ahead of the position stream, so anchoring on "label says grounded" froze
-- the anchor ~0.15-0.2s before the observed takeoff, and ordinary jumps were
-- judged from a stale, lower point. Standing on geometry is what makes "one
-- jump from here" legal; the label adds nothing. A correction never puts the
-- root below standing height on the floor under it
-- (`SpatialQueries.QueryFloorBelow`), so a missed support read can at worst
-- set the character down on the floor, never into it.
--
-- Replication ordering: the position stream and the claim that justifies a
-- rise or a hold (DoubleJump, WallRun, WallCling) travel separately, so the
-- character can be seen doing a move before the claim for it is accepted.
-- `claimLagSeconds` bounds that gap, never a guessed slack: the descent curve runs that
-- much late, and an excess must outlast it before it's corrected. A confirmed
-- excess is snapped down with upward velocity killed. Zero tolerance
-- otherwise (ARCHITECTURE §9); measure with VERTICAL_CEILING_DEBUG_LOGGING
-- before ever changing that.
-- "Here, plus one jump": for a grounded, swimming, teleported or noclipping
-- character. A jump off a floor the server can vouch for also inherits the
-- floor's own upward speed (`floorRiseSpeed`, zero otherwise).
local function anchorVerticalCeiling(
	session: PlayerSession,
	constants: EffectiveMovementConstants,
	now: number
)
	local jumpSpeed = math.max(constants.JumpPower, session.groundLaunchSpeed or 0)
		+ session.floorRiseSpeed
	session.verticalCeilingY = session.rootPart.Position.Y
		+ TraversalMath.BallisticRise(jumpSpeed, Workspace.Gravity)
	session.verticalApexAt = now + TraversalMath.TimeToApex(jumpSpeed, Workspace.Gravity)
	session.verticalExcessSince = nil
	session.verticalAnchorY = session.rootPart.Position.Y
	session.verticalAnchorAt = now
	session.verticalRaisedAt = nil
	session.verticalRaisedBy = 0
	local pending = session.groundRaise
	if pending then
		if now - pending.at <= claimLagSeconds(session) then
			session.verticalCeilingY += pending.rise
			session.verticalApexAt = math.max(session.verticalApexAt, pending.apexAt)
			session.verticalRaisedAt = pending.at
			session.verticalRaisedBy = pending.rise
		else
			session.groundRaise = nil
		end
	end
end

local function enforceVerticalCeiling(session: PlayerSession, constants: EffectiveMovementConstants)
	local rootPart = session.rootPart
	local character = session.humanoid.Parent :: Instance
	local y = rootPart.Position.Y
	local now = os.clock()
	local dt = now - session.verticalCheckAt
	session.verticalCheckAt = now
	local jumpRise = TraversalMath.BallisticRise(constants.JumpPower, Workspace.Gravity)
	local humanoidState = session.humanoid:GetState()

	-- Swimming in real terrain water re-anchors like ground does (designer
	-- answer 2026-09-24): the character can swim up to the surface and jump
	-- out. The water check is the server's own, so the label alone buys
	-- nothing outside water.
	local swimming = humanoidState == Enum.HumanoidStateType.Swimming
		and SpatialQueries.IsInWater(rootPart.Position)

	-- Touching real ground after a fast launch has topped out ends its flight:
	-- the allowance gets one landing grace (so the landing itself is judged
	-- at the launch's speed), then lapses even if the mirror never lands.
	if
		session.supported
		and session.airborneAllowedSpeed
		and not session.airborneAllowanceExpiresAt
		and now > session.verticalApexAt
	then
		session.airborneAllowanceExpiresAt = now + LANDING_MOMENTUM_GRACE_SECONDS
	end

	if JUMP_LAUNCH_CAPTURE and RunService:IsStudio() then
		local capture = session.jumpCapture
		if session.supported or swimming then
			if capture and capture.peakY > capture.takeoffY then
				local peak = capture.peakY - capture.takeoffY
				print(
					string.format(
						"[JumpCapture] %s from=%s peak=%.2f toPeak=%.3fs launch=%.1f JumpPower=%.1f raisedBy=%.1f",
						session.player.Name,
						capture.from,
						peak,
						capture.peakAt - capture.takeoffAt,
						math.sqrt(2 * Workspace.Gravity * peak),
						constants.JumpPower,
						session.verticalRaisedBy
					)
				)
			end
			session.jumpCapture = nil
		elseif not capture then
			session.jumpCapture = {
				from = tostring(session.previousState),
				takeoffY = session.verticalAnchorY,
				takeoffAt = session.verticalAnchorAt,
				peakY = y,
				peakAt = now,
			}
		elseif y > capture.peakY then
			capture.peakY = y
			capture.peakAt = now
		end
	end

	if NoclipState.IsActive(session.player) or session.supported or swimming then
		anchorVerticalCeiling(session, constants, now)
		if swimming then
			-- Water ends a leap's flight the way landing does (re-audit N-001).
			session.airborneAllowedSpeed = nil
		end
		return
	end

	-- A wall the server's own probes confirm is holding the character up, so
	-- the descent clock waits: WallRun only sinks slowly and WallCling holds
	-- still, and both have server-enforced time limits.
	local current = session.fsm.current
	if current == MovementStates.WallRun or current == MovementStates.WallCling then
		session.verticalApexAt = math.max(session.verticalApexAt, now)
	end

	-- Climbing (ladders, trusses; designer answer 2026-09-24) on something the
	-- server confirms is a ladder (re-audit N-004): the ceiling rises at most
	-- at this player's own speed cap (the Humanoid climbs at a fraction of
	-- WalkSpeed, and the cap bounds WalkSpeed), and never more than one jump
	-- above where the character really is, so a climb can't bank height to
	-- spend later. The ladder holds the character up like a wall does.
	-- Grabbing one ends a leap's flight (N-001), so the allowance goes first
	-- and the climb rate is the ordinary cap.
	if
		humanoidState == Enum.HumanoidStateType.Climbing
		and SpatialQueries.QueryClimbable(rootPart, character)
	then
		session.airborneAllowedSpeed = nil
		local climbed = math.min(
			math.max(session.verticalCeilingY, y) + effectiveMaxSpeed(session, constants) * dt,
			y + jumpRise
		)
		session.verticalCeilingY = math.max(session.verticalCeilingY, climbed)
		session.verticalApexAt = math.max(session.verticalApexAt, now)
	end

	-- Unsupported from here on (support re-anchored above): the takeoff a
	-- pending SlideJump launch was waiting for has happened.
	session.groundLaunchSpeed = nil
	session.groundRaise = nil

	local lag = claimLagSeconds(session)
	local ceiling = TraversalMath.DescentCeiling(
		session.verticalCeilingY,
		session.verticalApexAt + lag,
		now,
		Workspace.Gravity
	)

	local excess = y - ceiling
	if excess <= 0 then
		session.verticalExcessSince = nil
		return
	end

	if not session.verticalExcessSince then
		session.verticalExcessSince = now
	end
	local excessFor = now - (session.verticalExcessSince :: number)

	if VERTICAL_CEILING_DEBUG_LOGGING then
		print(
			string.format(
				"[VerticalCeiling] %s state=%s y=%.2f ceiling=%.2f apexY=%.2f pastApex=%.3fs excess=%.2f for=%.3fs lag=%.3fs supported=%s",
				session.player.Name,
				tostring(session.fsm.current),
				y,
				ceiling,
				session.verticalCeilingY,
				now - session.verticalApexAt,
				excess,
				excessFor,
				lag,
				tostring(session.supported)
			)
		)
	end

	if excessFor < lag then
		return
	end

	local raisedAt = session.verticalRaisedAt
	reportViolation(session, "VerticalCeiling", {
		excess = excess,
		excessFor = excessFor,
		pastApex = now - session.verticalApexAt,
		lag = lag,
		vy = rootPart.AssemblyLinearVelocity.Y,
		aboveAnchor = y - session.verticalAnchorY,
		sinceAnchor = now - session.verticalAnchorAt,
		raisedBy = session.verticalRaisedBy,
		-- -1: nothing has raised the ceiling since the last anchor.
		sinceRaise = if raisedAt then now - raisedAt else -1,
	})

	-- Never below standing height on whatever lies between here and the
	-- target, so the snap can't bury the legs in a floor.
	local target = ceiling
	local floorY = SpatialQueries.QueryFloorBelow(
		rootPart,
		character,
		excess + MovementConstants.RigRootHeightAboveFeet
	)
	if floorY then
		target = math.max(target, floorY + MovementConstants.RigRootHeightAboveFeet)
	end

	local position = rootPart.Position
	rootPart.CFrame = (rootPart.CFrame - position) + Vector3.new(position.X, target, position.Z)
	local velocity = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, math.min(velocity.Y, 0), velocity.Z)
	session.verticalExcessSince = nil
	-- A flight that broke ballistics is no longer a leap (N-001).
	session.airborneAllowedSpeed = nil
end

-- Debug overlay (F4, developer-only, docs/MovementSystem.md): one-way broadcast of this
-- session's mirrored state to the owning client only, so the overlay can flag
-- client/server disagreement instead of only showing the client's own
-- (self-reported) view -- that's the actual point of the panel. Restricted to
-- developers so a normal player's client never even receives this traffic.
--
-- `violations` (docs/MovementSystem.md §10) sends ViolationTracker's bounded history,
-- not just the running count -- `ageSeconds` is computed fresh right here,
-- every broadcast, from this server's own `os.clock()` rather than sending
-- the raw recorded timestamp, since the two machines' clocks aren't
-- comparable (unlike `elapsed`, which is already a duration, not a moment).
local function broadcastDebugState(session: PlayerSession)
	if not DeveloperAllowlist.IsDeveloper(session.player) then
		return
	end
	-- Gated on the panel actually being open (docs/MovementSystem.md §4.4,
	-- `docs/MovementSystem.md` §4.4 cleanup), not just on developer status --
	-- this used to fire every Heartbeat to every connected developer
	-- regardless of whether they had F4 open at all, which is exactly the
	-- "no blanket per-Heartbeat network cost" mistake this file's own
	-- optimization standards (§7/§11) warn against for new code.
	if not DebugOverlayState.IsOpen(session.player) then
		return
	end

	local context = buildContext(session)
	local violation = speedViolations:Get(session.player)
	local now = os.clock()

	local violationEntries: { { flatDelta: number, maxDistance: number, elapsed: number, ageSeconds: number } } =
		{}
	if violation then
		for _, entry in ipairs(violation.history) do
			table.insert(violationEntries, {
				flatDelta = entry.flatDelta,
				maxDistance = entry.maxDistance,
				elapsed = entry.elapsed,
				ageSeconds = now - entry.at,
			})
		end
	end

	Network.MovementDebugState.Fire(session.player, {
		state = DEBUG_STATE_NAMES[session.fsm.current],
		runDuration = if context.runDuration then context.runDuration :: number else nil,
		violationCount = if violation then violation.count else 0,
		violations = violationEntries,
	})
end

-- A claim travels separately from position replication: by the time one is
-- accepted, the client has already moved under the new move for about one
-- network leg. When the accept raises the cap, that stretch was budgeted at
-- the old cap, so the difference is credited for that leg (server-measured
-- ping, never anything the client sends) plus however long the claim waited
-- in a claim buffer. Capped at one speed-check window: anything older belongs
-- to a window that has already been judged.
local function creditClaimLatency(
	session: PlayerSession,
	capBefore: number,
	constants: EffectiveMovementConstants,
	bufferedFor: number?
)
	local capAfter = effectiveMaxSpeed(session, constants)
	if capAfter <= capBefore then
		return
	end
	local oneWay = math.max(session.player:GetNetworkPing(), 0) / 2
	local lag = math.min(oneWay + (bufferedFor or 0), MovementConstants.SpeedCheckIntervalSeconds)
	session.speedBudget += (capAfter - capBefore) * lag
end

-- WallRunState.Enter's one-time snap onto the cling distance moves the rig
-- along the wall normal, and a wall may tilt up to `WallDetectMaxUpDot`, so
-- the snap can lift the character slightly. Bounded by the farthest a
-- QueryWallRun hit can be from the root (cast reach plus sphere radius).
local function wallRunEntryMaxRise(constants: EffectiveMovementConstants): number
	local maxOffset = MovementConstants.WallRunSideCastDistance
		+ MovementConstants.WallRunSideCastRadius
	local maxNudge =
		math.max(constants.WallRunClingDistance, maxOffset - constants.WallRunClingDistance)
	return maxNudge * MovementConstants.WallDetectMaxUpDot
end

-- Shared acceptance bookkeeping for a WallRun entry landing -- whether it's
-- accepted on the FIRST attempt (`onClaimTraversalMove`) or a BUFFERED retry
-- a few Heartbeats later (`retryBufferedTraversalClaims`, see
-- `WallRunClaimBufferSeconds`) -- one source of truth so the two paths can
-- never drift out of sync with each other. Deliberately does NOT set
-- `wallRunEntryNormal` here -- see `mirrorPassiveTransitions`'s WallRun
-- branch for why that reference is anchored lazily off the Heartbeat loop's
-- own next throttled probe instead of whatever probe accepted the claim
-- (2026-09-19 fix for a spurious near-instant corner-exceeded force-exit).
local function acceptWallRunEntry(session: PlayerSession, constants: EffectiveMovementConstants)
	session.traversalEntryAt = os.clock()
	raiseVerticalCeiling(session, wallRunEntryMaxRise(constants), 0)
	session.wallRunEntryNormal = nil
	session.wallRunEntryInstance = nil
	session.pendingWallRunClaimUntil = nil
end

-- Shared acceptance bookkeeping for a WallCling entry -- same two-caller
-- reasoning as `acceptWallRunEntry` above (docs/MovementSystem.md §8.4):
-- whether accepted on the first attempt or a buffered retry a few Heartbeats
-- later (`pendingWallClingClaimUntil`), one source of truth.
local function acceptWallClingEntry(session: PlayerSession, bufferedFor: number?)
	session.traversalEntryAt = os.clock()
	session.wallClingEnteredAt = os.clock() - (bufferedFor or 0)
	session.wallClingBoostUsed = false
	session.pendingWallClingClaimUntil = nil
	session.pendingWallBoostClaimUntil = nil
end

-- Shared acceptance bookkeeping for a DoubleJump, first attempt or a buffered
-- retry (`pendingDoubleJumpClaimUntil`).
local function acceptDoubleJump(session: PlayerSession, constants: EffectiveMovementConstants)
	session.traversalEntryAt = os.clock()
	session.doubleJumpUsed = true
	session.doubleJumpLeftGround = false
	session.pendingDoubleJumpClaimUntil = nil
	raiseVerticalCeiling(
		session,
		TraversalMath.DoubleJumpMaxRise(
			constants.DoubleJumpForce,
			constants.DoubleJumpDecayDurationSeconds,
			Workspace.Gravity
		),
		TraversalMath.DoubleJumpTimeToApex(
			constants.DoubleJumpForce,
			constants.DoubleJumpDecayDurationSeconds,
			Workspace.Gravity
		)
	)
end

-- A DoubleJump/WallBoost claim the server finally refused (Studio only): the
-- client still performs the move, so the vertical ceiling will object next.
local function reportRejectedClaim(session: PlayerSession, claim: string)
	if not (SPEED_SANITY_DEBUG_LOGGING or RunService:IsStudio()) then
		return
	end
	print(
		string.format(
			"[TraversalClaim] %s claim=%s REJECTED current=%s grounded=%s supported=%s doubleJumpUsed=%s humanoid=%s",
			session.player.Name,
			claim,
			tostring(session.fsm.current),
			tostring(isSessionGrounded(session)),
			tostring(session.supported),
			tostring(session.doubleJumpUsed),
			session.humanoid:GetState().Name
		)
	)
end

-- Shared acceptance bookkeeping for a WallBoost launch, first attempt or a
-- buffered retry (`pendingWallBoostClaimUntil`).
local function acceptWallBoost(session: PlayerSession, constants: EffectiveMovementConstants)
	session.wallClingBoostUsed = true
	session.wallBoostStartedAt = os.clock()
	session.pendingWallBoostClaimUntil = nil
	raiseVerticalCeiling(
		session,
		TraversalMath.BallisticRise(constants.WallBoostUpwardForce, Workspace.Gravity),
		TraversalMath.TimeToApex(constants.WallBoostUpwardForce, Workspace.Gravity)
	)
end

-- Shared acceptance bookkeeping for a WallLeap launch -- same two-caller
-- reasoning as `acceptWallRunEntry` above.
local function acceptWallLeapLaunch(session: PlayerSession, context: MovementContext)
	local constants = context.constants
	session.traversalEntryAt = os.clock()

	-- The REAL fix for the "boost gets erased" playtest bug (2026-09-18):
	-- WallLeap's resulting speed doesn't decay -- Roblox applies no horizontal
	-- air drag, so the excess persists for the whole flight, and without this
	-- the flight would be measured against the ordinary Airborne cap and
	-- snapped back to the wall. Derived from server-known constants only
	-- (audit M-003): the old version added the client's replicated velocity,
	-- which a cheater could set to anything for one frame before the claim.
	-- `effectiveMaxSpeed` consults it; cleared on landing (`fsm.changed`).
	session.airborneAllowanceExpiresAt = nil
	session.airborneAllowedSpeed = TraversalMath.WallLeapMaxHorizontalSpeed(
		constants.WallRunSpeed,
		constants.WallRunClingMaxCorrectionSpeed,
		constants.WallLeapBurstForce,
		constants.WallLeapPushForce
	)
	raiseVerticalCeiling(
		session,
		TraversalMath.BallisticRise(constants.WallLeapUpwardForce, Workspace.Gravity),
		TraversalMath.TimeToApex(constants.WallLeapUpwardForce, Workspace.Gravity)
	)

	-- Mirrors the client's own synchronous two-step (WallLeapState.Enter):
	-- hand straight back to Airborne in the SAME call, matching the client's
	-- own FSM shape rather than leaving the mirror sitting in WallLeap for a
	-- Heartbeat. The server never re-derives or pushes its own velocity
	-- vector onto the character here (docs/MovementSystem.md §8.4) -- Roblox's own network
	-- ownership model keeps this player's physics client-authoritative, same
	-- as every other move in this file; this is legality plus the
	-- anti-exploit measures above, not a resimulation of the launch itself.
	--
	-- Wall-leap memory (docs/MovementSystem.md §4.6/§5): snapshotted BEFORE
	-- `wallRunEntryInstance` is cleared below, mirroring the client's own
	-- identical ordering in Movement/init.luau's `fsm.changed` handler.
	session.lastWallLeapWall = session.wallRunEntryInstance
	session.wallRunEntryNormal = nil
	session.wallRunEntryInstance = nil
	session.pendingWallLeapClaimUntil = nil
	session.fsm:RequestTransition(MovementStates.Airborne, context)
end

-- Heartbeat-driven follow-through for the claim-buffering set up in
-- `onClaimTraversalMove` below (see `WallRunClaimBufferSeconds`'s own comment
-- for the full root-cause reasoning: a claim can arrive before the server's
-- own replicated state has caught up to support it, purely from ordinary
-- Roblox replication lag on a fast, continuous gesture like a double jump
-- chained straight into a wall run). Retries the exact SAME legality gate
-- `onClaimTraversalMove` already ran -- `RequestTransition`'s real
-- `CanEnter`/topology check -- off whatever fresher server state THIS
-- Heartbeat has, every Heartbeat, until it succeeds or the buffer window
-- closes. Never invents new legality of its own.
local function bufferedFor(pendingUntil: number): number
	return MovementConstants.WallRunClaimBufferSeconds - (pendingUntil - os.clock())
end

local function retryBufferedTraversalClaims(session: PlayerSession)
	local now = os.clock()
	local current = session.fsm.current

	-- Airborne is where a buffered WallRun/WallCling claim can land. DoubleJump
	-- keeps the buffer alive too (audit M-009): the server times DoubleJump ->
	-- Airborne from its own later accept, so a claim for the client's
	-- post-DoubleJump move can arrive while the mirror is still a few ms short
	-- of handing back to Airborne. Anything else (landed, moved into some other
	-- move entirely) means the gesture this claim wanted no longer applies.
	local airborneFamily = current == MovementStates.Airborne
		or current == MovementStates.DoubleJump

	if session.pendingWallRunClaimUntil then
		if now >= session.pendingWallRunClaimUntil or not airborneFamily then
			session.pendingWallRunClaimUntil = nil
		elseif current == MovementStates.Airborne then
			local context = buildContext(session)
			local capBefore = effectiveMaxSpeed(session, context.constants)
			local waited = bufferedFor(session.pendingWallRunClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallRun, context) then
				acceptWallRunEntry(session, context.constants)
				creditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- Landed, or otherwise left the WallRun/Airborne family entirely (e.g. the
	-- buffered WallRun claim above never itself landed) -- the leap this claim
	-- wanted no longer makes sense.
	if session.pendingWallLeapClaimUntil then
		current = session.fsm.current
		if
			now >= session.pendingWallLeapClaimUntil
			or (current ~= MovementStates.WallRun and current ~= MovementStates.Airborne)
		then
			session.pendingWallLeapClaimUntil = nil
		elseif current == MovementStates.WallRun then
			local context = buildContext(session)
			local capBefore = effectiveMaxSpeed(session, context.constants)
			local waited = bufferedFor(session.pendingWallLeapClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallLeap, context) then
				acceptWallLeapLaunch(session, context)
				creditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- Same buffered-retry shape as WallRun/WallLeap above (playtest bug
	-- 2026-09-19, see `pendingWallClingClaimUntil`'s own PlayerSession
	-- comment) -- retries the exact SAME `CanEnter[WallCling]`/topology gate
	-- `onClaimTraversalMove` already ran, off whatever fresher
	-- `session.wallClingQuery` this Heartbeat's own `updateWallClingQuery`
	-- call already produced (that call runs earlier in the same Heartbeat,
	-- before `mirrorPassiveTransitions`/this function -- see the Heartbeat
	-- loop's own ordering comment).
	if session.pendingWallClingClaimUntil then
		current = session.fsm.current
		if
			now >= session.pendingWallClingClaimUntil
			or (current ~= MovementStates.Airborne and current ~= MovementStates.DoubleJump)
		then
			session.pendingWallClingClaimUntil = nil
		elseif current == MovementStates.Airborne then
			local context = buildContext(session)
			local waited = bufferedFor(session.pendingWallClingClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallCling, context) then
				acceptWallClingEntry(session, waited)
			end
		end
	end

	-- WallBoost's photo finish on `WallBoostMinClingSeconds` (see
	-- `pendingWallBoostClaimUntil`). Only meaningful while still clinging.
	if session.pendingWallBoostClaimUntil then
		current = session.fsm.current
		if now >= session.pendingWallBoostClaimUntil or current ~= MovementStates.WallCling then
			session.pendingWallBoostClaimUntil = nil
			reportRejectedClaim(session, "WallBoost")
		else
			local context = buildContext(session)
			local capBefore = effectiveMaxSpeed(session, context.constants)
			local waited = bufferedFor(session.pendingWallBoostClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallBoost, context) then
				acceptWallBoost(session, context.constants)
				creditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- DoubleJump waiting for the touchdown that refreshes it to show up in
	-- the position stream (see `pendingDoubleJumpClaimUntil`). The mirror may
	-- pass through a landing on the way, so only expiry abandons it.
	if session.pendingDoubleJumpClaimUntil then
		current = session.fsm.current
		if now >= session.pendingDoubleJumpClaimUntil then
			session.pendingDoubleJumpClaimUntil = nil
			reportRejectedClaim(session, "DoubleJump")
		elseif current == MovementStates.Airborne then
			local context = buildContext(session)
			local capBefore = effectiveMaxSpeed(session, context.constants)
			local waited = bufferedFor(session.pendingDoubleJumpClaimUntil)
			if session.fsm:RequestTransition(MovementStates.DoubleJump, context) then
				acceptDoubleJump(session, context.constants)
				creditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end
end

-- Sprint's own buffered retry (2026-09-21 "flagged switching Run->Sprint"
-- investigation, see `pendingSprintClaimUntil`'s own PlayerSession comment
-- for the full root-cause reasoning) -- same shape as
-- `retryBufferedTraversalClaims` above, kept as its own function rather than
-- folded in since Run/Sprint use the dwell-timestamp model, not the
-- resimulation model every claim in that function shares. Retries the exact
-- SAME `CanEnter[Sprint]` dwell check `onRequestMovementTransition` already
-- ran, off whatever fresher `runDuration` THIS Heartbeat's `buildContext`
-- produces, every Heartbeat, until it succeeds or the buffer window closes.
-- Never invents new legality of its own -- a still-too-early dwell simply
-- keeps failing `RequestTransition` the same way it would from a fresh claim.
local function retryBufferedSprintClaim(session: PlayerSession)
	if not session.pendingSprintClaimUntil then
		return
	end

	local now = os.clock()
	if now >= session.pendingSprintClaimUntil then
		session.pendingSprintClaimUntil = nil
		return
	end

	if session.fsm.current ~= MovementStates.Run then
		-- Demoted, landed into a different tier, or otherwise left Run
		-- entirely since the buffer was armed -- the Sprint this claim wanted
		-- no longer applies.
		session.pendingSprintClaimUntil = nil
		return
	end

	local context = buildContext(session)
	if not context.grounded then
		session.pendingSprintClaimUntil = nil
		return
	end

	local capBefore = effectiveMaxSpeed(session, context.constants)
	local waited = bufferedFor(session.pendingSprintClaimUntil)
	if session.fsm:RequestTransition(MovementStates.Sprint, context) then
		session.pendingSprintClaimUntil = nil
		creditClaimLatency(session, capBefore, context.constants, waited)
	end
end

-- The real exploit surface for the new traversal moves (docs/MovementSystem.md §7/§8;
-- docs/MovementSystem.md §8.4 for WallRun/WallLeap): a modified client could claim DoubleJump
-- without ever earning it (already airborne, air-jump not yet spent), or claim WallRun with no wall
-- nearby, or claim WallLeap without ever having actually earned WallRun. Legality is checked the
-- same way as every other claim in this file -- against this session's OWN mirrored FSM/context
-- (`CanEnter[WallRun]`, the SAME shared `StateRules` predicate the client evaluates, fed the
-- server's OWN `wallRunQuery`/`GetHorizontalVelocity`-equivalent read -- never a client-asserted
-- normal, tangent, or speed), never anything the client asserts. WallLeap needs no separate
-- predicate here beyond that shared check -- topology alone gates it (`StateRules.Transitions` only
-- has an edge INTO WallLeap from WallRun), so `RequestTransition` below already rejects the claim
-- outright unless this session is actually mirrored into WallRun, the same "you have to actually be
-- wall-running" legality WallLeapState's own client-side comment already explains.
local function onClaimTraversalMove(player: Player, claim: Network.ClaimableTraversalMove)
	local session = sessions[player]
	if not session then
		return
	end

	if not session.traversalRateLimiter:TryAcquire() then
		return
	end

	-- Root-cause fix, 2026-09-18 (real playtest bug: a "WallRun" claim
	-- arriving with `session.fsm.current` still `Run`, rejected purely on
	-- topology, even though the player had genuinely already left the
	-- ground) -- the mirror only advances passively once per server
	-- Heartbeat, off the LATEST replicated Humanoid state at the time that
	-- Heartbeat happens to run. A claim is a completely separate, asynchronous
	-- network arrival that can land BETWEEN two Heartbeats, before the one
	-- that would have caught the mirror up to `Airborne`. Rather than widen
	-- any tolerance to paper over that gap (docs/ARCHITECTURE.md §9), this
	-- re-runs the SAME passive-mirroring/wall-probe logic the Heartbeat loop
	-- already uses, right here, off the freshest replicated state available
	-- AT THE MOMENT the claim is actually processed. `mirrorPassiveTransitions`
	-- is context-driven with no per-call side effects beyond the state it's
	-- already meant to reflect, so calling it an extra time between two
	-- regularly-scheduled Heartbeats only ever catches the mirror up SOONER,
	-- never differently.
	-- `force = true`: unlike `mirrorPassiveTransitions`, `updateWallRunQuery`
	-- is internally throttled, so the plain call above wasn't actually fresh.
	-- `updateWallClingQuery` gets the identical forced-fresh treatment for the
	-- same reason (docs/MovementSystem.md §8.4).
	updateSupport(session)
	updateWallRunQuery(session, true)
	updateWallClingQuery(session, true)
	mirrorPassiveTransitions(session)

	local claimedState = if claim == "DoubleJump"
		then MovementStates.DoubleJump
		elseif claim == "WallRun" then MovementStates.WallRun
		elseif claim == "WallLeap" then MovementStates.WallLeap
		elseif claim == "WallCling" then MovementStates.WallCling
		elseif claim == "WallBoost" then MovementStates.WallBoost
		else nil
	if not claimedState then
		return
	end

	local context = buildContext(session)
	local constants = context.constants
	local capBefore = effectiveMaxSpeed(session, constants)
	if session.fsm:RequestTransition(claimedState, context) then
		if claimedState == MovementStates.DoubleJump then
			acceptDoubleJump(session, constants)
		elseif claimedState == MovementStates.WallRun then
			acceptWallRunEntry(session, constants)
		elseif claimedState == MovementStates.WallLeap then
			acceptWallLeapLaunch(session, context)
		elseif claimedState == MovementStates.WallCling then
			acceptWallClingEntry(session)
		elseif claimedState == MovementStates.WallBoost then
			acceptWallBoost(session, constants)
		end
		creditClaimLatency(session, capBefore, constants)
		return
	end

	-- Claim-buffering (2026-09-19 playtest fix -- see `WallRunClaimBufferSeconds`'s
	-- own comment for the full root-cause reasoning): a rejection here can
	-- simply mean the server's own replicated state hasn't caught up YET to
	-- support a claim the player genuinely, legitimately just earned. Buffer
	-- it and let `retryBufferedTraversalClaims` keep re-checking the SAME
	-- legality gate every Heartbeat until it either succeeds or this window
	-- closes -- a claim that's actually illegal (no wall anywhere, standing
	-- still, etc.) gets buffered exactly the same way, but simply never
	-- succeeds during that window, since the real `CanEnter`/topology check
	-- keeps running against it unchanged.
	if claimedState == MovementStates.WallRun then
		session.pendingWallRunClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.WallLeap then
		session.pendingWallLeapClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.WallCling then
		-- Same root cause as WallRun's own buffering above (playtest bug
		-- 2026-09-19): a rejection can simply mean the server's own
		-- replicated position/CFrame hasn't caught up yet to a wall the
		-- player only just moved into range of. Reuses
		-- `WallRunClaimBufferSeconds` rather than a second, unmeasured window
		-- -- see the field's own PlayerSession comment.
		session.pendingWallClingClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.DoubleJump then
		session.pendingDoubleJumpClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
		return
	elseif
		claimedState == MovementStates.WallBoost
		and session.fsm.current == MovementStates.WallCling
	then
		-- Still clinging, so the likely reason is the minimum cling time
		-- landing a few ms short on this side (see `pendingWallBoostClaimUntil`).
		session.pendingWallBoostClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
		return
	end

	-- WallBoost outside a cling isn't buffered (DoubleJump and in-cling
	-- WallBoost returned above), so this rejection is final.
	if claimedState == MovementStates.WallBoost then
		reportRejectedClaim(session, claim)
	end

	if
		WALL_TRAVERSAL_DEBUG_LOGGING
		and (claimedState == MovementStates.WallRun or claimedState == MovementStates.WallLeap)
	then
		print(
			string.format(
				"[WallTraversal] %s claim=%s REJECTED current=%s wallRunQuery=%s",
				player.Name,
				claim,
				tostring(session.fsm.current),
				tostring(context.wallRunQuery ~= nil)
			)
		)
	end
end

-- The one teardown path for a session (audit M-011/M-023): death, character
-- removal, replacement, and leaving all end here, so the session's trove is
-- destroyed exactly once and the Heartbeat loop stops touching the old rig.
local function destroySession(player: Player)
	local session = sessions[player]
	if session then
		sessions[player] = nil
		session._trove:Destroy()
	end
end

-- Per-player connections (CharacterAdded/CharacterRemoving), outliving any
-- single character life -- destroyed on PlayerRemoving.
local playerTroves: { [Player]: Trove.Trove } = {}

local function onPlayerAdded(player: Player)
	local playerTrove = Trove.new()
	playerTroves[player] = playerTrove

	local function onCharacterAdded(character: Model)
		destroySession(player)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
		-- The waits above yield; a newer character (or a leave) may have
		-- arrived meanwhile, and this stale rig must not claim the session.
		if player.Character ~= character or playerTroves[player] ~= playerTrove then
			return
		end
		local session = createSession(player, humanoid, rootPart)
		sessions[player] = session
		-- Movement-only teardown, never a combat-defeat trigger (ARCHITECTURE
		-- §12): a dead rig stops being mirrored/validated/corrected.
		session._trove:Connect(humanoid.Died, function()
			if sessions[player] == session then
				destroySession(player)
			end
		end)
	end

	playerTrove:Connect(player.CharacterAdded, onCharacterAdded)
	playerTrove:Connect(player.CharacterRemoving, function(character: Model)
		local session = sessions[player]
		if session and session.humanoid.Parent == character then
			destroySession(player)
		end
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	destroySession(player)
	local playerTrove = playerTroves[player]
	if playerTrove then
		playerTroves[player] = nil
		playerTrove:Destroy()
	end
	for _, tracker in pairs(violationTrackers) do
		tracker:Clear(player)
	end
end

-- The real exploit surface (see docs/ARCHITECTURE.md §5): a modified client could
-- claim Sprint without ever earning it. Legality is checked against this session's
-- OWN runEnteredAt timestamp -- never anything the client sends -- same
-- lag-compensation principle as parry (§4), applied to a locomotion transition.
local function onRequestMovementTransition(player: Player, claim: Network.ClaimableMovementState)
	local session = sessions[player]
	if not session then
		return
	end

	-- Crouch/Slide (docs/MovementSystem.md §4.2): these two DON'T name an FSM target
	-- state, unlike every other claim here -- they only set/clear this
	-- session's own `crouchHeld` flag. No dwell timer, no FSM attempt at all;
	-- `mirrorPassiveTransitions` (next Heartbeat) is what turns this into an
	-- actual transition, the same way it already turns `moveIntent` into
	-- Idle<->Walk. Resent by the client as a level every second (audit M-006),
	-- so both are idempotent and gated by their own limiter.
	if claim == "CameraLocked" or claim == "CameraUnlocked" then
		if session.levelRateLimiter:TryAcquire() then
			session.cameraLocked = claim == "CameraLocked"
		end
		return
	end

	if claim == "CrouchDown" or claim == "CrouchUp" then
		if not session.levelRateLimiter:TryAcquire() then
			return
		end
		if claim == "CrouchDown" then
			session.crouchHeld = true
		else
			session.crouchHeld = false
			-- Crouch-lock re-arm (SlideJump landing fix): mirrors the client's
			-- own `crouchSuppressed` clear, which happens whenever Ctrl is up --
			-- a CrouchUp level report IS that fact server-side.
			session.crouchSuppressed = false
		end
		return
	end

	if not session.rateLimiter:TryAcquire() then
		if SPEED_SANITY_DEBUG_LOGGING then
			-- Confirms/rules out the rate limiter itself as a cause of dropped
			-- legitimate claims (docs/MovementSystem.md §8) -- 5/second should never be
			-- reachable by normal play (one claim per Run/Sprint entry), so this
			-- firing during an ordinary playtest would point at the limiter, not
			-- at enforceSpeedSanity, as the actual bug.
			print(string.format("[SpeedSanity] %s RATE LIMITED claim=%s", player.Name, claim))
		end
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = buildContext(session)
	local capBefore = effectiveMaxSpeed(session, context.constants)

	if session.fsm:RequestTransition(claimedState, context) then
		creditClaimLatency(session, capBefore, context.constants)
		-- A fresh accept on either claim invalidates any earlier buffered
		-- Sprint retry (2026-09-21 investigation, see `pendingSprintClaimUntil`'s
		-- own PlayerSession comment): a new "Run" claim starts a brand new
		-- dwell cycle the old buffer knows nothing about, and a direct "Sprint"
		-- accept here means there's nothing left to retry.
		session.pendingSprintClaimUntil = nil

		if claimedState == MovementStates.Run then
			-- Backdated by half this player's measured RTT (docs/MovementSystem.md §8,
			-- fixed 2026-09-14) -- the claim carrying this instant already reached
			-- the server late, so stamping raw receipt time skews the server's
			-- dwell clock later than the client's own, which used to land a
			-- legitimate first Sprint claim right on the 3s boundary (near-even
			-- odds of rejection from jitter alone) instead of comfortably past it.
			local ping = player:GetNetworkPing()
			-- Guards `GetNetworkPing()` returning 0 (no sample yet -- e.g. this is
			-- the very first claim right after spawn) or an implausibly large
			-- reading: capped at half of `SprintThresholdSeconds` so a bad reading
			-- here can never backdate far enough to let Sprint be claimed with
			-- little to no real Run dwell.
			local backdateSeconds = if ping > 0
				then math.min(ping / 2, context.constants.SprintThresholdSeconds / 2)
				else 0
			session.runEnteredAt = os.clock() - backdateSeconds
		elseif SPEED_SANITY_DEBUG_LOGGING and context.runDuration then
			-- The server only ever sees "Sprint" claimed once its OWN runEnteredAt
			-- says the dwell is satisfied, so this is never negative -- it's purely
			-- how much the client's local dwell clock (which crossed the 3s
			-- threshold first, then had to round-trip this claim over the network)
			-- had already run past 3s by the time the server processed it. A
			-- consistently large number here is the claim-round-trip lag docs/MovementSystem.md §8
			-- asks to rule in or out as a rubber-banding cause.
			print(
				string.format(
					"[SpeedSanity] %s Sprint claim accepted, dwell overshoot=%.3fs",
					player.Name,
					(context.runDuration :: number) - context.constants.SprintThresholdSeconds
				)
			)
		end
		return
	end

	if SPEED_SANITY_DEBUG_LOGGING then
		-- Rejection path had NO visibility at all before this (2026-09-21
		-- "flagged switching Run->Sprint" investigation) -- the accept branch
		-- above already prints dwell overshoot, but a claim that fails
		-- `CanEnter`/topology here silently returns, leaving the server's
		-- mirror stuck one tier behind whatever the client already predicted
		-- and entered. That mismatch is what feeds `effectiveMaxSpeed` (keyed
		-- off `session.fsm.current`, never the client's state) a stale, lower
		-- cap, which is what `enforceSpeedSanity` then flags every
		-- `SpeedCheckIntervalSeconds` until the next resync claim
		-- (Movement/init.luau's `CLAIM_RESYNC_INTERVAL_SECONDS`) gets through --
		-- this print is what actually distinguishes "the dwell-backdate
		-- undercompensated real latency" from every other way this claim could
		-- have been rejected (already in that state, wrong topology edge, not
		-- grounded), instead of guessing which one to fix.
		print(
			string.format(
				"[SpeedSanity] %s claim=%s REJECTED current=%s grounded=%s runDuration=%s threshold=%.2f preAirborne=%s",
				player.Name,
				claim,
				tostring(session.fsm.current),
				tostring(context.grounded),
				if context.runDuration
					then string.format("%.3f", context.runDuration :: number)
					else "nil",
				context.constants.SprintThresholdSeconds,
				tostring(context.preAirborneLocomotion)
			)
		)
	end

	-- Buffered Sprint retry (2026-09-21 investigation): the rejection logging
	-- above, run against a real playtest, showed every rejected "Sprint" claim
	-- landing with `runDuration` within single milliseconds of `threshold`
	-- while already grounded and mirrored into Run -- the client fires this
	-- claim the INSTANT its own local dwell clock crosses 3s, and the server's
	-- independently-tracked (if backdated) clock has to have ALSO already
	-- crossed by the time this arrives. That's an inherent photo finish no
	-- amount of backdate tuning removes -- the two machines' Heartbeat/frame
	-- boundaries simply don't align. Left unhandled, the session sat capped at
	-- RunSpeed until the client's next periodic resync claim
	-- (`CLAIM_RESYNC_INTERVAL_SECONDS`, a full second away), during which
	-- `enforceSpeedSanity` fired real corrections against real players -- the
	-- exact rubber-banding this investigation exists to fix. Buffering it here
	-- follows the SAME `pendingWallRunClaimUntil`/`retryBufferedTraversalClaims`
	-- idiom `onClaimTraversalMove` already established for this identical class
	-- of "claim arrived a beat before the server could agree" race, reusing
	-- `WallRunClaimBufferSeconds` rather than a second, unmeasured window (the
	-- same reuse `pendingWallClingClaimUntil` already justifies for the
	-- identical reason). Only armed when grounded-and-Run is the ONLY thing
	-- that could have failed `CanEnter[Sprint]` -- any other rejection (still
	-- airborne, wrong topology edge entirely) has nothing to retry toward.
	if
		claimedState == MovementStates.Sprint
		and session.fsm.current == MovementStates.Run
		and context.grounded
	then
		session.pendingSprintClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	end
end

function MovementValidationService.Init()
	-- One-time workspace setup (docs/MovementSystem.md §4.2) -- collision group
	-- definitions replicate to every client automatically once registered
	-- here, so this never needs a client-side counterpart.
	CollisionGroups.RegisterGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Network.RequestMovementTransition.SetCallback(onRequestMovementTransition)
	Network.ClaimTraversalMove.SetCallback(onClaimTraversalMove)

	-- See DevToolsService's teleport handler: this is fired for any out-of-band
	-- character move (today, only the debug overlay's developer teleport) so
	-- enforceSpeedSanity doesn't measure the jump as an impossible speed and
	-- immediately snap the player back to where they were.
	CharacterTeleported:Connect(function(player: Player)
		local session = sessions[player]
		if session then
			resetSpeedWindow(session)
			anchorVerticalCeiling(session, MovementTuningState.GetEffective(player), os.clock())
		end
	end)

	-- The exemption hook for server-granted upward travel (audit M-001): lets
	-- knockback, launch pads or Qinggong lift a player without tripping the
	-- vertical ceiling, measured from wherever the player is right now. The
	-- grant is treated as a launch that tops out `rise` higher, so the descent
	-- check (re-audit N-002) waits as long as that launch would keep rising.
	VerticalAllowanceGranted:Connect(function(player: Player, rise: number)
		local session = sessions[player]
		if session then
			local granted = math.max(rise, 0)
			session.verticalCeilingY =
				math.max(session.verticalCeilingY, session.rootPart.Position.Y + granted)
			session.verticalApexAt = math.max(
				session.verticalApexAt,
				os.clock()
					+ TraversalMath.TimeToApex(
						math.sqrt(2 * Workspace.Gravity * granted),
						Workspace.Gravity
					)
			)
		end
	end)

	-- Eight per-session checks run unconditionally for every player every
	-- Heartbeat -- each is already throttled internally (see e.g.
	-- SpeedCheckIntervalSeconds/SlideGroundRaycastThrottleSeconds/
	-- WallRunQueryThrottleSeconds/WallClingRecheckInterval), but staggering the
	-- OUTER loop itself (which players get checked which frame) is a real
	-- design decision, not a drive-by cleanup -- open scalability question for
	-- whenever a future traversal phase adds a ninth check here.
	--
	-- `updateSupport` runs first: every "is this character grounded" read in
	-- this Heartbeat (the wall probes, the mirror, the vertical ceiling) goes
	-- through `isSessionGrounded`, which needs this frame's support probe.
	-- `updateWallRunQuery`/`updateWallClingQuery` both run BEFORE
	-- `mirrorPassiveTransitions` for the same same-frame-race reason
	-- `updatePeakHeight` already does (docs/MovementSystem.md §8.4): the sustain check inside
	-- `mirrorPassiveTransitions` needs THIS frame's fresh probe, not last
	-- frame's. `retryBufferedTraversalClaims`/`retryBufferedSprintClaim` both
	-- run AFTER `mirrorPassiveTransitions` for the identical reason -- a
	-- buffered retry needs to see THIS frame's mirrored state (e.g. a landing
	-- `mirrorPassiveTransitions` just resolved), not last frame's. The vertical
	-- ceiling runs after every claim path, so a rise accepted this frame is
	-- already credited before it is measured.
	RunService.Heartbeat:Connect(function()
		for _, session in pairs(sessions) do
			local constants = MovementTuningState.GetEffective(session.player)
			updateSupport(session)
			updatePeakHeight(session)
			updateWallRunQuery(session)
			updateWallClingQuery(session)
			mirrorPassiveTransitions(session)
			retryBufferedTraversalClaims(session)
			retryBufferedSprintClaim(session)
			updateSlideGroundQuery(session, constants)
			enforceSpeedSanity(session, constants)
			enforceVerticalCeiling(session, constants)
			broadcastDebugState(session)
		end
	end)
end

return MovementValidationService
