--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

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

-- Grounded-family states (docs/MOVEMENT.md §10 rework) -- same "which states
-- count as grounded" question `session.peakHeight`'s seed/clear edge (below,
-- in `createSession`'s `fsm.changed` handler) needs answered server-side. See
-- Shared/FSM/MovementStateGroups.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- client's own GROUNDED_STATES in Movement/init.luau).
local GROUNDED_STATES = MovementStateGroups.Grounded

type PlayerSession = {
	player: Player,
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	rateLimiter: RateLimiter.RateLimiter,
	runEnteredAt: number?,
	speedCheckPosition: Vector3,
	speedCheckAt: number,
	-- Landing-momentum grace (docs/MOVEMENT.md §5, added 2026-09-14): the state
	-- this session was in immediately before its most recent transition, and
	-- when that transition happened -- generic over which transition, never
	-- keyed to "landed from Airborne" specifically. See `effectiveMaxSpeed`.
	previousState: MovementState?,
	lastTransitionAt: number,
	-- The one signal in this whole system with no natural replicated
	-- equivalent (docs/MOVEMENT.md §9) -- set/cleared by the "CrouchDown"/
	-- "CrouchUp" claims, never derived. Every resulting FSM consequence
	-- (CrouchIdle/CrouchWalk/Slide entry and exit, crouched landing) is then
	-- mirrored passively off this flag by `mirrorPassiveTransitions`, the same
	-- way Idle<->Walk already is off `moveIntent`.
	crouchHeld: boolean,
	-- DoubleJump per-life flag (TRAVERSAL-ROADMAP.md §4/§7) -- mirrors the
	-- client's own flag 1:1: set on an accepted "DoubleJump" claim, reset the
	-- instant this session's mirror lands (same "Airborne -> grounded" edge
	-- `mirrorPassiveTransitions` already detects for the crouched-landing
	-- branch).
	doubleJumpUsed: boolean,
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
	-- HardLanding fall-height tracking (docs/MOVEMENT.md §10 rework) -- mirrors
	-- the client's own `peakHeight` 1:1, off this session's OWN
	-- `rootPart.Position.Y` (server-trusted, never anything the client
	-- asserts, docs/ARCHITECTURE.md §3): the peak height reached since this
	-- session's mirror last left the ground, nil while grounded. Grown every
	-- Heartbeat (`updatePeakHeight`, called before `mirrorPassiveTransitions`
	-- for the same same-frame-race reason as the client's own Heartbeat
	-- ordering comment), seeded/cleared in `createSession`'s `fsm.changed`
	-- handler.
	peakHeight: number?,
	-- HardLanding movement lock (docs/MOVEMENT.md §10 rework) -- mirrors the
	-- client's own `HardLandingState`'s `lockedUntil`: this server's own
	-- `os.clock()` deadline, set the instant this session's mirror enters
	-- HardLanding, read by `mirrorPassiveTransitions`'s own HardLanding branch
	-- to decide when to resolve back out. `maxSpeedForState`'s HardLanding ->
	-- 0 cap is what actually makes the lock authoritative (via
	-- `enforceSpeedSanity`'s existing position correction) -- this timestamp
	-- only decides when the MIRROR itself is allowed to leave the state.
	hardLandingLockUntil: number?,
	-- Entry snapshot for DoubleJump's resimulation (TRAVERSAL-ROADMAP.md §7.1),
	-- reused as-is for WallRun's own entry timestamp (Wall Run & Leap Mechanic
	-- Guideline §6 -- only one traversal move is ever active at a time, so one
	-- generic "when did I enter this move" field covers both) -- this server's
	-- OWN `os.clock()` the instant it accepted the claim, never anything the
	-- client sends. `enforceDoubleJumpTrajectory` measures elapsed time from
	-- this for DoubleJump; `mirrorPassiveTransitions`'s WallRun branch uses it
	-- against `WallRunMaxDurationSeconds` the same way.
	traversalEntryAt: number?,
	-- WallRun's own side-cast probe, server side (guideline §1/§6) -- the
	-- SAME `SpatialQueries.QueryWallRun` pure function the client calls,
	-- never anything the client reports about wall position/normal. Updated
	-- every Heartbeat this session isn't grounded (`updateWallRunQuery`),
	-- independent of its current mirrored state -- needed both for
	-- `CanEnter[WallRun]`'s legality check at claim time and for
	-- `mirrorPassiveTransitions`'s sustain check while already in WallRun.
	wallRunQuery: SpatialQueries.WallRunQueryResult?,
	wallRunQueryAt: number,
	-- WallRun's locked entry normal (guideline §6) -- the server's OWN
	-- `wallRunQuery.normal` at the instant the claim was accepted, stored
	-- once and never re-read live, same "locked at Entry" rule the client's
	-- own `WallRunState` follows. Compared against the LIVE `wallRunQuery`
	-- every Heartbeat (`mirrorPassiveTransitions`) to detect a corner/curve
	-- exceeding `WallRunMaxNormalDeviationDegrees`.
	wallRunEntryNormal: Vector3?,
	-- The physical wall part itself (docs/WallClimbingPlan.md §2/§9), same
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
	-- WallLeap's own speed-sanity ceiling (playtest fix 2026-09-18) -- see
	-- `onClaimTraversalMove`'s WallLeap branch for the full reasoning: a
	-- flat one-shot suspension window (`speedSanitySuspendedUntil`, sized
	-- for DoubleJump's DECAYING impulse) isn't enough for WallLeap, whose
	-- boosted speed doesn't decay on its own -- Roblox applies no horizontal
	-- air drag, so the excess speed persists for the entire flight. This is
	-- a real, computed ceiling (current speed + burst + push at the instant
	-- the claim was accepted), not a guessed tolerance, consulted by
	-- `effectiveMaxSpeed` for as long as this session hasn't landed since.
	-- Cleared the instant it does (`fsm.changed`'s own landing bookkeeping,
	-- same edge `peakHeight` already clears on).
	wallLeapAllowedSpeed: number?,
	-- Set the instant a ClaimTraversalMove is accepted, cleared once expired
	-- (TRAVERSAL-ROADMAP.md §7.4) -- suspends `enforceSpeedSanity`'s
	-- horizontal check for `TraversalSpeedSanityGraceSeconds` so a legitimate
	-- traversal move's own residual momentum on landing doesn't get
	-- immediately flagged as a violation.
	speedSanitySuspendedUntil: number?,
	-- Independent rate limit for ClaimTraversalMove (TRAVERSAL-ROADMAP.md §11)
	-- -- kept separate from `rateLimiter` (RequestMovementTransition's own),
	-- same orthogonal-cooldown principle Run/Sprint's limiter already
	-- established, just applied to the new event.
	traversalRateLimiter: RateLimiter.RateLimiter,
	-- Slide's own ground-normal cache (TRAVERSAL-ROADMAP.md §7.5/§8 Phase 3) --
	-- the server's own copy of the same throttled-raycast pattern
	-- SlideState.Update runs client-side, off `SpatialQueries.QueryGround`
	-- (the SAME pure function, never a second hand-synced geometry read). Only
	-- ever populated while this session is mirrored into Slide/SlideJump;
	-- `updateSlideGroundQuery` clears it the instant it isn't, so a stale
	-- normal from a slide that ended moments ago can never leak into
	-- `maxSpeedForState`'s cap for an unrelated state.
	slideGroundQuery: SpatialQueries.GroundQueryResult?,
	slideGroundQueryAt: number,
	-- WallCling's own probe (docs/WallClimbingPlan.md §7/§11.2) -- the SAME
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
	-- Server-owned re-grab lockout (docs/WallClimbingPlan.md §3.5/§4/§11.2) --
	-- the ONLY authoritative copy (docs/ARCHITECTURE.md §3); the client's own
	-- `WallClingState.lockoutUntil` is prediction only. Set by this session's
	-- OWN force-exit bookkeeping (`mirrorPassiveTransitions`'s WallCling
	-- branch), never anything the client claims.
	wallClingLockoutUntil: number?,
	-- Per-cling flag mirroring the client's own `boostUsedThisCling` 1:1 --
	-- false on every accepted WallCling claim, true the instant a WallBoost
	-- claim is accepted; `CanEnter[WallBoost]` reads it via `buildContext`.
	wallClingBoostUsed: boolean,
	-- Wall-leap memory, server side (docs/WallClimbingPlan.md §2/§9) -- the
	-- server's OWN copy of `wallRunEntryInstance` at the instant a WallLeap
	-- launch was accepted, never anything the client asserts. Cleared on
	-- landing, same edge `peakHeight`/`wallLeapAllowedSpeed` already clear on.
	lastWallLeapWall: BasePart?,
	-- WallBoost's own launch timestamp (docs/WallClimbingPlan.md §11.4/§11.5)
	-- -- a DEDICATED field, not a reuse of the generic `traversalEntryAt`
	-- (unlike WallCling's own duration check, which does reuse it): the boost
	-- envelope has to keep being enforced for a while AFTER the mirror has
	-- already returned to Airborne (`effectiveMaxSpeed`), the same
	-- "outlives the state itself" lifetime `wallLeapAllowedSpeed` already
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
}

-- Rate limit for RequestMovementTransition, independent of the FSM's own legality
-- check -- see docs/ARCHITECTURE.md §5 and Shared/Util/RateLimiter.luau. A
-- network-layer concern, not gameplay tuning, so it lives here rather than in
-- MovementConstants.
local TRANSITION_CLAIMS_PER_SECOND = 5

-- Rate limit for ClaimTraversalMove, independent of RequestMovementTransition's
-- own limiter above (TRAVERSAL-ROADMAP.md §11) -- same reasoning, separate
-- counter so a burst against one event can never eat into the other's budget.
local TRAVERSAL_CLAIMS_PER_SECOND = 5

-- Starting-point tolerance for `enforceDoubleJumpTrajectory` below -- flagged
-- unmeasured on purpose (docs/MOVEMENT.md §9's "measured, not guessed" bar has
-- no data yet for this brand-new check): generous enough to absorb ordinary
-- gravity/replication variance on top of the claimed impulse without being a
-- no-op. Revisit only with real measured data from
-- TRAVERSAL_TRAJECTORY_DEBUG_LOGGING below -- the same "capture before
-- retuning" pattern SpeedToleranceMultiplier's own comment
-- (MovementConstants.luau) already established for SPEED_SANITY_DEBUG_LOGGING.
local TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE = 15

-- Absorbs standing-still jitter during HardLanding's WalkSpeed=0 lock without
-- tolerating a real WASD movement attempt.
local HARD_LANDING_RESIDUAL_SPEED_TOLERANCE = 6

-- Diagnostic capture for `enforceDoubleJumpTrajectory`, same pattern as
-- SPEED_SANITY_DEBUG_LOGGING below -- off by default, prints actual/expected/
-- delta vertical velocity every Heartbeat DoubleJump is active so
-- TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE above can eventually be sized from a
-- real playtest capture instead of the unmeasured starting-point guess it is
-- today (docs/MOVEMENT.md §9).
local TRAVERSAL_TRAJECTORY_DEBUG_LOGGING = false

-- Temporary instrumentation for the 2026-09-13 Sprint-rubber-banding
-- investigation (docs/MOVEMENT.md §5) -- prints real numbers instead of guessing
-- at a tolerance. Flip on for a playtest, off for normal play; left in (not
-- deleted) since Stage 2's WallRun/etc. validation will want the same kind of
-- capture again.
local SPEED_SANITY_DEBUG_LOGGING = true

-- Diagnostic capture for the 2026-09-18 "WallLeap boost gets erased" bug --
-- same pattern as the other *_DEBUG_LOGGING flags above. Prints why a
-- WallRun/WallLeap claim was rejected, or why `mirrorPassiveTransitions`
-- force-exits WallRun. Re-enabled (still 2026-09-18) after the SpeedSanity
-- rubber-band came back post-retune (WallRunSpeed 26->35,
-- WallLeapBurstForce/PushForce 14/16->75/75) -- need to confirm whether the
-- claim is being rejected again (same root cause as before) versus something
-- new, rather than guessing at a second patch on top of the first.
local WALL_TRAVERSAL_DEBUG_LOGGING = true

-- Sized from a real 2026-09-14 playtest capture (docs/MOVEMENT.md §5), not a
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

local MovementValidationService = {}

local sessions: { [Player]: PlayerSession } = {}
local speedViolations = ViolationTracker.new()

local function isGrounded(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
end

-- The server never sees raw WASD key state (that's client-only), so it can't
-- literally reconstruct "is W held" the way InputController does. Instead this
-- mirrors the same forward/backward/strafe *classification* SprintState.Update
-- relies on, geometrically: forward/backward from facing's dot with MoveDirection
-- past a deadzone, strafeLeft/strafeRight from the sign of the analogous cross
-- product (same convention as LocomotionAnimator.resolveDirectionBucket -- positive
-- means Right). Both inputs (rootPart.CFrame, humanoid.MoveDirection) are
-- server-trusted replicated state, not anything the client asserts directly, which
-- is what makes this a real fix rather than trusting the client's own claim (see
-- docs/MOVEMENT.md §5).
--
-- Forward/backward use a deadzone (this session's effective
-- SprintForwardDeadzone, docs/MOVEMENT.md §8 -- MovementConstants' shipped
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

-- `constants` is this session's EFFECTIVE tuning (docs/MOVEMENT.md §8) --
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
		grounded = isGrounded(session.humanoid:GetState()),
		jumping = session.humanoid:GetState() == Enum.HumanoidStateType.Jumping,
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
		-- The server's OWN throttled probe (guideline §1/§6, `updateWallRunQuery`
		-- below) -- never anything the client reports.
		wallRunQuery = session.wallRunQuery,
		-- The server's OWN throttled probe (docs/WallClimbingPlan.md §7/§11.2,
		-- `updateWallClingQuery` below) -- never anything the client reports.
		wallClingQuery = session.wallClingQuery,
		-- Real replicated `rootPart.CFrame.LookVector` -- reuses the same
		-- `facing` value already computed above for `classifyMoveIntent`,
		-- never a second read.
		facingDirection = facing,
		wallClingLockoutUntil = session.wallClingLockoutUntil,
		wallClingBoostUsed = session.wallClingBoostUsed,
		lastWallLeapWall = session.lastWallLeapWall,
		-- Still an open design decision (TRAVERSAL-ROADMAP.md §0/§3) --
		-- "always available" until a real Qinggong/stamina resource exists,
		-- same placeholder the client uses.
		qinggong = math.huge,
		-- Landing-resume fix, hardened 2026-09-18 (see MovementTypes.luau's
		-- own field comment) -- the same replicated property
		-- `mirrorPassiveTransitions`'s own Sprint-demotion branch already
		-- trusts for the identical "facing lags MoveDirection while
		-- unlocked" reason.
		cameraLocked = not session.humanoid.AutoRotate,
		constants = constants,
	}
end

-- Idle/Walk/Airborne need no remote (Humanoid state already replicates), so the
-- mirror follows them passively here. Run/Sprint are only ever *entered* via the
-- explicit claim below -- this never attempts either as a target, so an unclaimed
-- client can never end up mirrored as Run/Sprint no matter what MoveDirection says.
-- Sprint's demotion back to Run IS handled here, on the server's own initiative
-- (see docs/MOVEMENT.md §5) -- it doesn't wait for the client to re-claim Run.
local function mirrorPassiveTransitions(session: PlayerSession)
	local context = buildContext(session)
	local current = session.fsm.current

	-- Slide -> SlideJump -> Airborne (docs/MOVEMENT.md §9): reactive off the
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
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	if current == MovementStates.Airborne then
		if context.grounded then
			-- Landing while Ctrl is held goes to the crouch-variant instead of
			-- Idle/Walk (docs/MOVEMENT.md §9) -- a single-tick decision, same
			-- as AirborneState.Update's own client-side landing logic.
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				-- DoubleJump reset (TRAVERSAL-ROADMAP.md §4): mirrors the
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
	-- finishes (TRAVERSAL-ROADMAP.md §4/§7.2), on the server's own initiative,
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

	-- WallRun's anti-exploit backbone (Wall Run & Leap Mechanic Guideline §6)
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
				-- Same lazy-anchor timing as the normal above (docs/
				-- WallClimbingPlan.md §2/§9) -- captured here, not at claim
				-- time, so `lastWallLeapWall` (set off this when a leap is
				-- accepted) agrees with whichever wall the corner-deviation
				-- check itself is actually anchored to.
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

	-- WallCling's anti-exploit backbone (docs/WallClimbingPlan.md §11.2/§11.3)
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
			-- Only Timeout applies a lockout here (docs/WallClimbingPlan.md
			-- §4's exit-reason table) -- a server-detected WallLost leaves
			-- `wallClingLockoutUntil` untouched, same "none" the client's own
			-- WallLost branch already applies.
			if durationExceeded then
				session.wallClingLockoutUntil = os.clock()
					+ context.constants.WallClingTimeoutLockout
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallBoost (docs/WallClimbingPlan.md §11.4): a short, fixed window off
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

	-- HardLanding (docs/MOVEMENT.md §10 rework): mirrors `HardLandingState.
	-- Update` client-side exactly -- losing the ground mid-lock is involuntary
	-- and takes priority over the lock timer (nothing left to lock the player
	-- TO); otherwise holds until this session's own `hardLandingLockUntil`
	-- (set server-side, off this session's own effective tuning, on the
	-- `fsm.changed` edge into HardLanding -- never anything the client
	-- claims), then re-resolves the SAME landing decision Airborne/DoubleJump
	-- use. `context.fallHeight` is already nil by this point (cleared the
	-- instant HardLanding was entered), so this always resolves to an
	-- ordinary grounded target, never back into HardLanding again.
	if current == MovementStates.HardLanding then
		if not context.grounded then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
			return
		end
		if session.hardLandingLockUntil and os.clock() < session.hardLandingLockUntil then
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
		-- Nominal decay estimate (docs/MOVEMENT.md §9): the server never
		-- tracks Slide's exact real velocity -- its speed cap is a flat
		-- SprintSpeed ceiling (see `maxSpeedForState`), not a simulated curve
		-- -- this only estimates WHEN the client's own real decay should have
		-- crossed CrouchSpeed, using the nominal tier `previousState` carried
		-- in (Run's RunSpeed or Sprint's SprintSpeed) rather than a physics
		-- read. Any drift between this estimate and the client's own
		-- (velocity-based) decay is absorbed by the existing landing-momentum
		-- grace (`effectiveMaxSpeed`) the instant this demotes into a
		-- CrouchSpeed cap -- not a new, separate tolerance.
		local entrySpeed = if session.previousState == MovementStates.Sprint
			then context.constants.SprintSpeed
			else context.constants.RunSpeed
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
	-- already gives it (docs/MOVEMENT.md §9). CrouchWalk is gated behind
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
		and not session.humanoid.AutoRotate
		and not context.moveIntent.forward
	then
		-- Same demotion condition as SprintState.Update client-side (backpedal or
		-- pure strafe drops Sprint), enforced independently of whether a modified
		-- client ever sends the matching reclaim.
		--
		-- Gated on `not session.humanoid.AutoRotate` (found during the 2026-09-13
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
		-- `AutoRotate` itself is a plain replicated Humanoid property the
		-- server already trusts elsewhere (`CharacterMover`/`FacingController`
		-- toggle it, same as `WalkSpeed`), so this costs no new trust assumption.
		--
		-- This narrows, rather than removes, server enforcement while unlocked:
		-- the "no input at all -> Idle" branch above and `enforceSpeedSanity`'s
		-- speed cap both still apply unconditionally. The one residual gap is
		-- narrow and low-severity -- a modified client could hold Sprint's speed
		-- cap (not Run's) while moving backward, unlocked, without ever
		-- backpedal-demoting -- documented in docs/MOVEMENT.md §5 rather than
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

-- HardLanding fall-height tracking, server side (docs/MOVEMENT.md §10
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
	if session.peakHeight then
		session.peakHeight = math.max(session.peakHeight, session.rootPart.Position.Y)
	end
end

-- Slide's own ground-normal probe, server side (TRAVERSAL-ROADMAP.md §7.5/§8
-- Phase 3) -- throttled the same way the client's own SlideState.Update is,
-- just off `os.clock()` deltas rather than a `dt` accumulator, since this
-- file's Heartbeat loop doesn't carry a `dt` of its own (every other
-- server-side duration here is already `os.clock()`-timestamp-based, e.g.
-- `speedCheckAt`/`lastTransitionAt`). Cleared to nil the instant this session
-- isn't mirrored into Slide/SlideJump, so a stale read can't outlive the
-- state it was measured for.
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

-- Server's own side-cast probe (Wall Run & Leap Mechanic Guideline §1/§6).
-- `force` bypasses the throttle for claim-time legality checks, which need
-- real current geometry (§3), not a stale Heartbeat-cadence sample (§9).
local function updateWallRunQuery(session: PlayerSession, force: boolean?)
	if isGrounded(session.humanoid:GetState()) then
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

-- WallCling's own forward-cast probe, server side (docs/WallClimbingPlan.md
-- §7/§11.2/§11.3) -- same throttle-with-force-bypass shape as
-- `updateWallRunQuery` above, off `WallClingRecheckInterval` (the SAME
-- non-tunable structural cadence the client's own sustain-check uses, kept
-- fixed rather than added to live tuning for the identical "server-only
-- anti-cheat plumbing" reasoning `WallRunQueryThrottleSeconds` already has).
-- Continuous while airborne (not just while mirrored into WallCling) so a
-- claim evaluated the instant Space is pressed already has a fresh sample,
-- same reasoning `wallRunQuery` is kept continuously fresh rather than only
-- probed on demand.
local function updateWallClingQuery(session: PlayerSession, force: boolean?)
	if isGrounded(session.humanoid:GetState()) then
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
-- own cached ground-normal and the session's real, physics-owned
-- `AssemblyLinearVelocity` direction (already server-trusted ground truth
-- elsewhere in this file, e.g. `enforceDoubleJumpTrajectory`'s own read of
-- the Y component) rather than anything the client asserts about its
-- direction.
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
-- Crouch/Slide additions (docs/MOVEMENT.md §9): CrouchIdle/CrouchWalk cap at
-- CrouchSpeed, same "own dedicated tier" treatment as Walk/Run.
--
-- Slide/SlideJump cap became a FORMULA, not a flat tier (TRAVERSAL-ROADMAP.md
-- §7.5, Phase 3): `SprintSpeed * SlideEntrySpeedMultiplier` -- the SAME
-- boosted ceiling `SlideState.Enter`/`SlideJumpState.Enter` clamp to
-- client-side (docs/MOVEMENT.md §12, 2026-09-15 entry-speed tuning pass;
-- before that pass this was a bare `SprintSpeed`, same reasoning as
-- Airborne's existing ceiling) -- PLUS `slopeAmplification`, the same
-- downhill top-up `TraversalMath.SlideSlopeAmplification` grants the client,
-- so a real slope-boosted slide doesn't rubber-band against a cap that only
-- ever assumed flat ground. `slopeAmplification` defaults to 0 for every call
-- site that doesn't have a live ground read to pass (e.g. `effectiveMaxSpeed`'s
-- own `previousCap` lookup below, which only needs a generous flat ceiling
-- for grace purposes, never a precise live figure).
local function maxSpeedForState(
	state: MovementState,
	constants: EffectiveMovementConstants,
	slopeAmplification: number?
): number
	if state == MovementStates.Run then
		return constants.RunSpeed
	elseif state == MovementStates.Slide or state == MovementStates.SlideJump then
		return constants.SprintSpeed * constants.SlideEntrySpeedMultiplier
			+ (slopeAmplification or 0)
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
		-- back to Airborne in the same call, guideline §6) -- this branch only
		-- matters for `effectiveMaxSpeed`'s `previousState` grace lookup right
		-- after one of them, and `speedSanitySuspendedUntil`'s own exemption
		-- window already covers the actual launch instant.
		return constants.SprintSpeed
	elseif state == MovementStates.WallRun then
		-- Live-capped at the mechanic's OWN tuned speed (guideline §6),
		-- deliberately NOT suspended like DoubleJump/WallLeap's one-shot
		-- impulses -- WallRun is sustained, so exempting the whole hold would
		-- let a modified client fly at any speed for as long as it claims
		-- WallRun. `enforceSpeedSanity` stays live throughout, just raised to
		-- this cap instead of Airborne's lower SprintSpeed ceiling.
		return constants.WallRunSpeed
	elseif state == MovementStates.WallCling then
		-- No horizontal drift while clinging (docs/WallClimbingPlan.md §5/§11.5)
		-- -- a fixed, non-tunable literal, not `constants.WallClingSpeedCeiling`
		-- (deliberately excluded from live tuning, docs/ARCHITECTURE.md §9's
		-- "no band-aid validation": any non-zero value needs a specific,
		-- measured, documented cause, not a knob a developer can nudge away a
		-- false flag with).
		return MovementConstants.WallClingSpeedCeiling
	elseif state == MovementStates.WallBoost then
		-- Same "one-shot impulse, real enforcement lives elsewhere" shape as
		-- DoubleJump/WallLeap above -- WallBoost's actual envelope is a
		-- computed, decaying ceiling (`TraversalMath.WallBoostSpeedCeilingAt`),
		-- enforced by `effectiveMaxSpeed` off `session.wallBoostStartedAt`
		-- instead of a flat tier here; this branch only matters for the
		-- `previousState` grace lookup right after the mirror hands back to
		-- Airborne.
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

-- Landing-momentum grace (docs/MOVEMENT.md §5, added 2026-09-14): distinct from
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
local function effectiveMaxSpeed(
	session: PlayerSession,
	constants: EffectiveMovementConstants
): number
	local currentCap = maxSpeedForState(
		session.fsm.current,
		constants,
		slideSlopeAmplification(session, constants)
	)

	-- WallLeap's own computed ceiling (playtest fix 2026-09-18) -- takes over
	-- from the ordinary Airborne/SprintSpeed cap for as long as this session
	-- hasn't landed since the leap (see `onClaimTraversalMove`'s WallLeap
	-- branch and the field's own comment on `PlayerSession`). `math.max`, not
	-- an unconditional override -- never LOWERS the cap below whatever the
	-- current state would already allow.
	if session.wallLeapAllowedSpeed and session.wallLeapAllowedSpeed > currentCap then
		currentCap = session.wallLeapAllowedSpeed
	end

	-- WallBoost's own computed ceiling (docs/WallClimbingPlan.md §11.5) --
	-- same `math.max`-not-override shape as `wallLeapAllowedSpeed` above, and
	-- for the identical reason: the mirror can already be back in Airborne by
	-- the time this evaluates (WallBoostStateDuration is short), but the real
	-- physical impulse is still decaying under gravity for longer than that,
	-- so this has to keep being consulted off `session.wallBoostStartedAt`
	-- regardless of `session.fsm.current`. The envelope naturally ends itself
	-- once it decays below the normal Airborne/SprintSpeed ceiling -- no fixed
	-- grace duration needed, exactly as the plan's own formula intends.
	if session.wallBoostStartedAt then
		local boostCeiling = TraversalMath.WallBoostSpeedCeilingAt(
			os.clock() - session.wallBoostStartedAt,
			constants.WallBoostUpwardForce,
			constants.WallBoostSeparationSpeed,
			Workspace.Gravity
		)
		if boostCeiling > currentCap then
			currentCap = boostCeiling
		end
	end

	-- Skips the grace below -- it's sized for an ordinary landing's brief
	-- momentum tail, not a multi-second lock.
	if session.fsm.current == MovementStates.HardLanding then
		return currentCap
	end

	local previousState = session.previousState
	if not previousState then
		return currentCap
	end

	local previousCap = maxSpeedForState(previousState, constants)
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

local function createSession(player: Player, humanoid: Humanoid, rootPart: BasePart): PlayerSession
	local fsm = StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	local session: PlayerSession = {
		player = player,
		humanoid = humanoid,
		rootPart = rootPart,
		fsm = fsm,
		rateLimiter = RateLimiter.new(TRANSITION_CLAIMS_PER_SECOND, 1),
		runEnteredAt = nil,
		speedCheckPosition = rootPart.Position,
		speedCheckAt = os.clock(),
		previousState = nil,
		lastTransitionAt = os.clock(),
		crouchHeld = false,
		doubleJumpUsed = false,
		crouchSuppressed = false,
		preAirborneLocomotion = nil,
		peakHeight = nil,
		hardLandingLockUntil = nil,
		traversalEntryAt = nil,
		speedSanitySuspendedUntil = nil,
		traversalRateLimiter = RateLimiter.new(TRAVERSAL_CLAIMS_PER_SECOND, 1),
		slideGroundQuery = nil,
		slideGroundQueryAt = 0,
		wallRunQuery = nil,
		wallRunQueryAt = 0,
		wallRunEntryNormal = nil,
		wallRunEntryInstance = nil,
		wallLeapAllowedSpeed = nil,
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
	}

	-- Reset the speed-sanity baseline on EVERY FSM transition, not just Sprint
	-- entry (found during the 2026-09-13 rubber-banding investigation): any
	-- transition can change `maxSpeedForState`'s cap, and Humanoid's WalkSpeed
	-- changes are not instant -- its ground controller accelerates/decelerates
	-- toward the new target over a real, documented handful of frames, it doesn't
	-- snap velocity immediately (docs/ARCHITECTURE.md §9's own example of an
	-- acceptable tolerance is exactly this class of thing). A window that
	-- straddles a transition boundary would compare a mix of old- and new-tier
	-- motion against only the new tier's cap -- most sharply on a large drop
	-- (Sprint/Airborne -> Walk on landing), where residual momentum can still
	-- exceed the new, much lower cap for a moment. Starting the window fresh at
	-- the boundary sidesteps needing to quantify that transient's length at all,
	-- rather than padding `SpeedToleranceMultiplier` to guess-cover it.
	fsm.changed:Connect(function(next: MovementState, previous: MovementState)
		local now = os.clock()
		session.speedCheckPosition = rootPart.Position
		session.speedCheckAt = now

		-- Landing-momentum grace bookkeeping (see `effectiveMaxSpeed` below) --
		-- just records what state this session was in and when, regardless of
		-- which states are involved; `effectiveMaxSpeed` is what decides whether
		-- that's actually a cap decrease worth gracing.
		session.previousState = previous
		session.lastTransitionAt = now

		-- HardLanding fall-height bookkeeping (docs/MOVEMENT.md §10 rework) --
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
			-- WallLeap ceiling bookkeeping (playtest fix 2026-09-18) -- cleared
			-- the instant this session actually lands, same edge as
			-- `peakHeight` just above, so an elevated post-leap speed
			-- allowance can never linger as a standing exploit once back on
			-- the ground.
			session.wallLeapAllowedSpeed = nil
			-- WallCling/WallBoost bookkeeping (docs/WallClimbingPlan.md §2/
			-- §11.5), same landing edge as the two clears just above.
			session.lastWallLeapWall = nil
			session.wallBoostStartedAt = nil
		end

		-- HardLanding lock deadline (docs/MOVEMENT.md §10 rework) -- mirrors
		-- the client's own `HardLandingState.Enter` timestamp exactly, off
		-- this session's own EFFECTIVE tuning (never a client-claimed
		-- duration) so `mirrorPassiveTransitions`'s own HardLanding branch
		-- knows exactly when the client-side lock is expected to release.
		if next == MovementStates.HardLanding then
			session.hardLandingLockUntil = now
				+ MovementTuningState.GetEffective(player).HardLandingDurationSeconds
		end

		-- Passability (docs/MOVEMENT.md §9): the SERVER's own copy, keyed off
		-- its own mirrored state -- never the client's. This is the
		-- authoritative copy every OTHER client's view of this character (and
		-- the server's own collision awareness) is built from; the owning
		-- client's identical, independent write in Movement/init.luau is only
		-- for that client's own local physics simulation feel.
		CollisionGroups.Apply(humanoid.Parent :: Model, next)

		if SPEED_SANITY_DEBUG_LOGGING then
			local constants = MovementTuningState.GetEffective(player)
			local previousCap = maxSpeedForState(previous, constants)
			local newCap = maxSpeedForState(next, constants)
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

	return session
end

-- Lightweight anti-noclip/speed-hack net (docs/MOVEMENT.md §5): not a full
-- predict-validate-correct loop (no raycasts, no world geometry) -- Phase 1 has
-- nothing spatial to validate yet, just "did this player cover more ground than
-- their currently-mirrored tier allows." Sampled over a fixed interval rather than
-- every Heartbeat: per-frame `CFrame` replication from an owning client arrives in
-- bursts, not evenly, so a raw frame-to-frame delta would false-positive on normal
-- replication jitter long before it caught a real speed hack. Vertical (Y) motion
-- is deliberately excluded -- falling/jumping isn't gated by any WalkSpeed tier,
-- and this check has no business policing gravity.
--
-- Exempted entirely while `NoclipState.IsActive` (docs/MOVEMENT.md §8) -- the
-- scouting tool's whole point is to move faster than any tier's cap allows, so
-- without this exemption it would rubber-band the very thing it exists for.
-- Checked against the SERVER's own authorized record, never a client-reported
-- flag (docs/ARCHITECTURE.md §3) -- DevToolsService.luau is the only writer.
local function enforceSpeedSanity(session: PlayerSession, constants: EffectiveMovementConstants)
	if NoclipState.IsActive(session.player) then
		return
	end

	-- Traversal exemption window (TRAVERSAL-ROADMAP.md §7.4) -- suspended
	-- entirely (not just baseline-reset) for a short grace after a
	-- ClaimTraversalMove is accepted, so a legitimate move's own residual
	-- momentum on landing doesn't immediately read as a violation. Cleared
	-- lazily here rather than on a timer -- once expired, this check simply
	-- stops short-circuiting and the field is left stale until the next
	-- claim overwrites it, same "no separate invalidation bookkeeping"
	-- reasoning `buildContext`'s own comment already uses for `constants`.
	if session.speedSanitySuspendedUntil and os.clock() < session.speedSanitySuspendedUntil then
		return
	end

	local now = os.clock()
	local elapsed = now - session.speedCheckAt
	if elapsed < MovementConstants.SpeedCheckIntervalSeconds then
		return
	end

	local position = session.rootPart.Position
	local previous = session.speedCheckPosition
	local flatDelta = Vector3.new(position.X - previous.X, 0, position.Z - previous.Z)
	local maxDistance = effectiveMaxSpeed(session, constants)
		* elapsed
		* constants.SpeedToleranceMultiplier

	if flatDelta.Magnitude > maxDistance then
		-- Unconditional (not gated behind SPEED_SANITY_DEBUG_LOGGING below): every
		-- correction is worth seeing in the console as it happens, not just during
		-- an opt-in debug session.
		print(
			string.format(
				"[SpeedSanity] %s state=%s flatDelta=%.2f maxDistance=%.2f elapsed=%.3f",
				session.player.Name,
				tostring(session.fsm.current),
				flatDelta.Magnitude,
				maxDistance,
				elapsed
			)
		)
		-- The detail captured here (docs/MOVEMENT.md §8) is exactly the same
		-- flatDelta/maxDistance/elapsed data the print above already has --
		-- ViolationTracker keeps a bounded history of it instead of only the
		-- running count, so broadcastDebugState can show the overlay's last
		-- few corrections, not just how many there have been.
		speedViolations:Record(session.player, {
			flatDelta = flatDelta.Magnitude,
			maxDistance = maxDistance,
			elapsed = elapsed,
		})

		local corrected = Vector3.new(previous.X, position.Y, previous.Z)
		session.rootPart.CFrame = (session.rootPart.CFrame - position) + corrected
		position = corrected
	end

	session.speedCheckPosition = position
	session.speedCheckAt = now
end

-- Debug overlay (F4, developer-only, docs/MOVEMENT.md): one-way broadcast of this
-- session's mirrored state to the owning client only, so the overlay can flag
-- client/server disagreement instead of only showing the client's own
-- (self-reported) view -- that's the actual point of the panel. Restricted to
-- developers so a normal player's client never even receives this traffic.
--
-- `violations` (docs/MOVEMENT.md §8) sends ViolationTracker's bounded history,
-- not just the running count -- `ageSeconds` is computed fresh right here,
-- every broadcast, from this server's own `os.clock()` rather than sending
-- the raw recorded timestamp, since the two machines' clocks aren't
-- comparable (unlike `elapsed`, which is already a duration, not a moment).
local function broadcastDebugState(session: PlayerSession)
	if not DeveloperAllowlist.IsDeveloper(session.player) then
		return
	end
	-- Gated on the panel actually being open (docs/MOVEMENT.md §10,
	-- `TRAVERSAL-ROADMAP.md` Phase 0 cleanup), not just on developer status --
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
		for _, entry in violation.history do
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

-- DoubleJump's own resimulation slice (TRAVERSAL-ROADMAP.md §7.2) -- the
-- simplest possible version of the "full trajectory resimulation" decision,
-- proportionate to DoubleJump having no spatial claim and no continuous
-- input: compares real vertical velocity against
-- `TraversalMath.DoubleJumpVerticalVelocity` (the SAME function the client's
-- own DoubleJumpState calls) seeded from this session's own entry-snapshot
-- timestamp, never the client-reported one. Vertical only -- horizontal
-- speed during DoubleJump is already covered by `enforceSpeedSanity`'s own
-- cap via `maxSpeedForState`.
local function enforceDoubleJumpTrajectory(
	session: PlayerSession,
	constants: EffectiveMovementConstants
)
	if session.fsm.current ~= MovementStates.DoubleJump or not session.traversalEntryAt then
		return
	end

	local elapsed = os.clock() - (session.traversalEntryAt :: number)
	local expected = TraversalMath.DoubleJumpVerticalVelocity(
		elapsed,
		constants.DoubleJumpForce,
		constants.DoubleJumpDecayDurationSeconds
	)
	local actual = session.rootPart.AssemblyLinearVelocity.Y

	if TRAVERSAL_TRAJECTORY_DEBUG_LOGGING then
		print(
			string.format(
				"[TrajectoryDebug] %s actual=%.2f expected=%.2f delta=%.2f",
				session.player.Name,
				actual,
				expected,
				actual - expected
			)
		)
	end

	if actual > expected + TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE then
		local velocity = session.rootPart.AssemblyLinearVelocity
		session.rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, expected, velocity.Z)
	end
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
local function acceptWallRunEntry(session: PlayerSession)
	session.traversalEntryAt = os.clock()
	session.speedCheckPosition = session.rootPart.Position
	session.speedCheckAt = os.clock()
	session.wallRunEntryNormal = nil
	session.wallRunEntryInstance = nil
	session.pendingWallRunClaimUntil = nil
end

-- Shared acceptance bookkeeping for a WallCling entry -- same two-caller
-- reasoning as `acceptWallRunEntry` above (docs/WallClimbingPlan.md §11.2):
-- whether accepted on the first attempt or a buffered retry a few Heartbeats
-- later (`pendingWallClingClaimUntil`), one source of truth.
local function acceptWallClingEntry(session: PlayerSession)
	session.traversalEntryAt = os.clock()
	session.speedCheckPosition = session.rootPart.Position
	session.speedCheckAt = os.clock()
	session.wallClingBoostUsed = false
	session.pendingWallClingClaimUntil = nil
end

-- Shared acceptance bookkeeping for a WallLeap launch -- same two-caller
-- reasoning as `acceptWallRunEntry` above.
local function acceptWallLeapLaunch(session: PlayerSession, context: MovementContext)
	session.traversalEntryAt = os.clock()
	session.speedCheckPosition = session.rootPart.Position
	session.speedCheckAt = os.clock()
	-- One-shot launch, same short exemption DoubleJump's own impulse gets --
	-- sized to cover the single frame the impulse needs to register, never a
	-- sustained exemption (guideline §6).
	session.speedSanitySuspendedUntil = os.clock()
		+ MovementConstants.TraversalSpeedSanityGraceSeconds

	-- The REAL fix for the "boost gets erased" playtest bug (2026-09-18): the
	-- suspension window above only covers the launch INSTANT, but WallLeap's
	-- resulting speed doesn't decay the way DoubleJump's impulse does --
	-- Roblox applies no horizontal air drag, so the excess speed persists for
	-- the whole flight. Without this, the very first `enforceSpeedSanity`
	-- check after the window above expired would measure the whole flight
	-- against the ordinary Airborne/SprintSpeed cap and snap the player
	-- straight back to the wall, discarding the entire leap. A conservative
	-- upper bound -- current speed + burst + push SUMMED, not
	-- vector-combined -- so this never needs to match the client's own
	-- `TraversalMath.WallLeapVelocity` bit for bit: real vector addition of
	-- two roughly perpendicular components is always <= this sum.
	-- `effectiveMaxSpeed` consults it; cleared the instant this session lands
	-- (`fsm.changed` above).
	session.wallLeapAllowedSpeed = context.horizontalVelocity.Magnitude
		+ context.constants.WallLeapBurstForce
		+ context.constants.WallLeapPushForce

	-- Mirrors the client's own synchronous two-step (WallLeapState.Enter):
	-- hand straight back to Airborne in the SAME call, matching the client's
	-- own FSM shape rather than leaving the mirror sitting in WallLeap for a
	-- Heartbeat. The server never re-derives or pushes its own velocity
	-- vector onto the character here (guideline §6) -- Roblox's own network
	-- ownership model keeps this player's physics client-authoritative, same
	-- as every other move in this file; this is legality plus the
	-- anti-exploit measures above, not a resimulation of the launch itself.
	--
	-- Wall-leap memory (docs/WallClimbingPlan.md §2/§9): snapshotted BEFORE
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
local function retryBufferedTraversalClaims(session: PlayerSession)
	local now = os.clock()

	if session.pendingWallRunClaimUntil then
		if now >= session.pendingWallRunClaimUntil then
			session.pendingWallRunClaimUntil = nil
		elseif session.fsm.current == MovementStates.Airborne then
			local context = buildContext(session)
			if session.fsm:RequestTransition(MovementStates.WallRun, context) then
				acceptWallRunEntry(session)
			end
		else
			-- No longer airborne (landed, or moved into some other move
			-- entirely) -- the gesture this claim wanted no longer applies.
			session.pendingWallRunClaimUntil = nil
		end
	end

	if session.pendingWallLeapClaimUntil then
		if now >= session.pendingWallLeapClaimUntil then
			session.pendingWallLeapClaimUntil = nil
		elseif session.fsm.current == MovementStates.WallRun then
			local context = buildContext(session)
			if session.fsm:RequestTransition(MovementStates.WallLeap, context) then
				acceptWallLeapLaunch(session, context)
			end
		elseif session.fsm.current ~= MovementStates.Airborne then
			-- Landed, or otherwise left the WallRun/Airborne family entirely
			-- (e.g. the buffered WallRun claim above never itself landed) --
			-- the leap this claim wanted no longer makes sense.
			session.pendingWallLeapClaimUntil = nil
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
		if now >= session.pendingWallClingClaimUntil then
			session.pendingWallClingClaimUntil = nil
		elseif session.fsm.current == MovementStates.Airborne then
			local context = buildContext(session)
			if session.fsm:RequestTransition(MovementStates.WallCling, context) then
				acceptWallClingEntry(session)
			end
		else
			-- No longer airborne (landed, or moved into some other move
			-- entirely) -- the gesture this claim wanted no longer applies.
			session.pendingWallClingClaimUntil = nil
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

	if session.fsm:RequestTransition(MovementStates.Sprint, context) then
		session.pendingSprintClaimUntil = nil
	end
end

-- The real exploit surface for the new traversal moves (TRAVERSAL-ROADMAP.md
-- §6/§7; Wall Run & Leap Mechanic Guideline §6 for WallRun/WallLeap): a
-- modified client could claim DoubleJump without ever earning it (already
-- airborne, air-jump not yet spent), or claim WallRun with no wall nearby,
-- or claim WallLeap without ever having actually earned WallRun. Legality is
-- checked the same way as every other claim in this file -- against this
-- session's OWN mirrored FSM/context (`CanEnter[WallRun]`, the SAME shared
-- `StateRules` predicate the client evaluates, fed the server's OWN
-- `wallRunQuery`/`GetHorizontalVelocity`-equivalent read -- never a
-- client-asserted normal, tangent, or speed), never anything the client
-- asserts. WallLeap needs no separate predicate here beyond that shared
-- check -- topology alone gates it (`StateRules.Transitions` only has an
-- edge INTO WallLeap from WallRun), so `RequestTransition` below already
-- rejects the claim outright unless this session is actually mirrored into
-- WallRun, the same "you have to actually be wall-running" legality
-- WallLeapState's own client-side comment already explains.
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
	-- same reason (docs/WallClimbingPlan.md §11.2).
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
	if session.fsm:RequestTransition(claimedState, context) then
		if claimedState == MovementStates.DoubleJump then
			session.traversalEntryAt = os.clock()
			session.speedCheckPosition = session.rootPart.Position
			session.speedCheckAt = os.clock()
			session.doubleJumpUsed = true
			-- Exemption window (TRAVERSAL-ROADMAP.md §7.4, shipped alongside
			-- Phase 1 per the roadmap's own risk register -- without it, this
			-- move's residual momentum on landing would immediately rubber-band
			-- against `enforceSpeedSanity`'s cap for the tier it's landing into).
			session.speedSanitySuspendedUntil = os.clock()
				+ MovementConstants.TraversalSpeedSanityGraceSeconds
		elseif claimedState == MovementStates.WallRun then
			acceptWallRunEntry(session)
		elseif claimedState == MovementStates.WallLeap then
			acceptWallLeapLaunch(session, context)
		elseif claimedState == MovementStates.WallCling then
			acceptWallClingEntry(session)
		elseif claimedState == MovementStates.WallBoost then
			session.wallClingBoostUsed = true
			session.wallBoostStartedAt = os.clock()
			session.speedCheckPosition = session.rootPart.Position
			session.speedCheckAt = os.clock()
		end
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

local function onPlayerAdded(player: Player)
	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
		sessions[player] = createSession(player, humanoid, rootPart)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if session then
		session.fsm:Destroy()
	end
	sessions[player] = nil
	speedViolations:Clear(player)
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

	if not session.rateLimiter:TryAcquire() then
		if SPEED_SANITY_DEBUG_LOGGING then
			-- Confirms/rules out the rate limiter itself as a cause of dropped
			-- legitimate claims (docs/MOVEMENT.md §5) -- 5/second should never be
			-- reachable by normal play (one claim per Run/Sprint entry), so this
			-- firing during an ordinary playtest would point at the limiter, not
			-- at enforceSpeedSanity, as the actual bug.
			print(string.format("[SpeedSanity] %s RATE LIMITED claim=%s", player.Name, claim))
		end
		return
	end

	-- Crouch/Slide (docs/MOVEMENT.md §9): these two DON'T name an FSM target
	-- state, unlike every other claim here -- they only set/clear this
	-- session's own `crouchHeld` flag. No dwell timer, no FSM attempt at all;
	-- `mirrorPassiveTransitions` (next Heartbeat) is what turns this into an
	-- actual transition, the same way it already turns `moveIntent` into
	-- Idle<->Walk. Simpler than Sprint's claim handling on purpose -- there's
	-- no dwell-timestamp machinery to copy where it doesn't apply.
	if claim == "CrouchDown" then
		session.crouchHeld = true
		return
	elseif claim == "CrouchUp" then
		session.crouchHeld = false
		-- Crouch-lock re-arm (SlideJump landing fix): mirrors the client's own
		-- `crouchSuppressed` clear on the same real key-up edge -- this claim
		-- IS that edge server-side, there's no separate signal to wait for.
		session.crouchSuppressed = false
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = buildContext(session)

	if session.fsm:RequestTransition(claimedState, context) then
		-- A fresh accept on either claim invalidates any earlier buffered
		-- Sprint retry (2026-09-21 investigation, see `pendingSprintClaimUntil`'s
		-- own PlayerSession comment): a new "Run" claim starts a brand new
		-- dwell cycle the old buffer knows nothing about, and a direct "Sprint"
		-- accept here means there's nothing left to retry.
		session.pendingSprintClaimUntil = nil

		if claimedState == MovementStates.Run then
			-- Backdated by half this player's measured RTT (docs/MOVEMENT.md §5,
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
			-- consistently large number here is the claim-round-trip lag docs/
			-- MOVEMENT.md §5 asks to rule in or out as a rubber-banding cause.
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
	-- One-time workspace setup (docs/MOVEMENT.md §9) -- collision group
	-- definitions replicate to every client automatically once registered
	-- here, so this never needs a client-side counterpart.
	CollisionGroups.RegisterGroups()

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
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
			session.speedCheckPosition = session.rootPart.Position
			session.speedCheckAt = os.clock()
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
	-- `updateWallRunQuery`/`updateWallClingQuery` both run BEFORE
	-- `mirrorPassiveTransitions` for the same same-frame-race reason
	-- `updatePeakHeight` already does (guideline §6): the sustain check inside
	-- `mirrorPassiveTransitions` needs THIS frame's fresh probe, not last
	-- frame's. `retryBufferedTraversalClaims`/`retryBufferedSprintClaim` both
	-- run AFTER `mirrorPassiveTransitions` for the identical reason -- a
	-- buffered retry needs to see THIS frame's mirrored state (e.g. a landing
	-- `mirrorPassiveTransitions` just resolved), not last frame's.
	RunService.Heartbeat:Connect(function()
		for _, session in sessions do
			local constants = MovementTuningState.GetEffective(session.player)
			updatePeakHeight(session)
			updateWallRunQuery(session)
			updateWallClingQuery(session)
			mirrorPassiveTransitions(session)
			retryBufferedTraversalClaims(session)
			retryBufferedSprintClaim(session)
			updateSlideGroundQuery(session, constants)
			enforceSpeedSanity(session, constants)
			enforceDoubleJumpTrajectory(session, constants)
			broadcastDebugState(session)
		end
	end)
end

return MovementValidationService
