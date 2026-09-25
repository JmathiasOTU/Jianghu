--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

-- The per-character-life record every validation module reads and writes
-- (one `PlayerSession` per character life, created and destroyed by
-- init.luau), and the map of live Sessions.ByPlayer by player.
local Sessions = {}

-- One flight for DebugFlags.JUMP_LAUNCH_CAPTURE: where it left the ground, which mirror
-- state it left from, and the highest point it reached.
type JumpCapture = {
	from: string,
	takeoffY: number,
	takeoffAt: number,
	peakY: number,
	peakAt: number,
}

export type PlayerSession = {
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
	-- for up to `ClaimTiming.ClaimLagSeconds` after it was accepted, instead of wiping it.
	groundRaise: { rise: number, apexAt: number, at: number }?,
	-- DebugFlags.JUMP_LAUNCH_CAPTURE: the flight in progress since the last anchor.
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
	-- keyed to "landed from Airborne" specifically. See `SpeedCaps.EffectiveMaxSpeed`.
	previousState: MovementState?,
	lastTransitionAt: number,
	-- The one signal in this whole system with no natural replicated
	-- equivalent (docs/MovementSystem.md §4.2) -- set/cleared by the "CrouchDown"/
	-- "CrouchUp" claims, never derived. Every resulting FSM consequence
	-- (CrouchIdle/CrouchWalk/Slide entry and exit, crouched landing) is then
	-- mirrored passively off this flag by `Mirror.PassiveTransitions`, the same
	-- way Idle<->Walk already is off `moveIntent`.
	crouchHeld: boolean,
	-- DoubleJump per-life flag (docs/MovementSystem.md §5/§8) -- mirrors the
	-- client's own flag 1:1: set on an accepted "DoubleJump" claim, reset the
	-- instant this session's mirror lands (same "Airborne -> grounded" edge
	-- `Mirror.PassiveTransitions` already detects for the crouched-landing
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
	-- into `context.crouchHeld` by `Context.Build` below so the server's own
	-- passive-transition/landing logic independently arrives at the same
	-- "don't auto-recrouch after a slide jump" decision the client does,
	-- never trusting the client's own masked value.
	crouchSuppressed: boolean,
	-- Landing-resume fix -- mirrors the client's own `preAirborneLocomotion`
	-- 1:1: Run/Sprint if that's the tier this session's mirror was in the
	-- instant it left the ground, nil otherwise. Set in
	-- `Mirror.PassiveTransitions`'s own "not grounded -> Airborne" branch
	-- (off `current`, the state about to be left, same source the client
	-- reads via `previous`), cleared the instant a landing resolves.
	preAirborneLocomotion: MovementState?,
	-- HardLanding fall-height tracking (docs/MovementSystem.md §4.4 rework) -- mirrors
	-- the client's own `peakHeight` 1:1, off this session's OWN
	-- `rootPart.Position.Y` (server-trusted, never anything the client
	-- asserts, docs/ARCHITECTURE.md §3): the peak height reached since this
	-- session's mirror last left the ground, nil while grounded. Grown every
	-- Heartbeat (`Probes.UpdatePeakHeight`, called before `Mirror.PassiveTransitions`
	-- for the same same-frame-race reason as the client's own Heartbeat
	-- ordering comment), seeded/cleared in `createSession`'s `fsm.changed`
	-- handler.
	peakHeight: number?,
	-- HardLanding movement lock (docs/MovementSystem.md §4.4 rework) -- mirrors the
	-- client's own `HardLandingState`'s `lockedUntil`: this server's own
	-- `os.clock()` deadline, set the instant this session's mirror enters
	-- HardLanding, read by `Mirror.PassiveTransitions`'s own HardLanding branch
	-- to decide when to resolve back out. The lock is enforced two ways: the
	-- HardLanding horizontal cap (`maxSpeedForState`) and the jump-escape
	-- check in `Mirror.PassiveTransitions` against `hardLandingLockPosition`.
	hardLandingLockUntil: number?,
	-- Entry snapshot for DoubleJump's resimulation (docs/MovementSystem.md §8), reused as-is for
	-- WallRun's own entry timestamp (docs/MovementSystem.md §8.4 -- only one traversal move is ever
	-- active at a time, so one generic "when did I enter this move" field covers both) -- this
	-- server's OWN `os.clock()` the instant it accepted the claim, never anything the client sends.
	-- `Mirror.PassiveTransitions` measures DoubleJump's own duration and WallRun's
	-- `WallRunMaxDurationSeconds` from it.
	traversalEntryAt: number?,
	-- WallRun's own side-cast probe, server side (docs/MovementSystem.md §4.5/§8.4) -- the
	-- SAME `SpatialQueries.QueryWallRun` pure function the client calls,
	-- never anything the client reports about wall position/normal. Updated
	-- every Heartbeat this session isn't grounded (`Probes.UpdateWallRunQuery`),
	-- independent of its current mirrored state -- needed both for
	-- `CanEnter[WallRun]`'s legality check at claim time and for
	-- `Mirror.PassiveTransitions`'s sustain check while already in WallRun.
	wallRunQuery: SpatialQueries.WallRunQueryResult?,
	wallRunQueryAt: number,
	-- WallRun's locked entry normal (docs/MovementSystem.md §8.4) -- the server's OWN
	-- `wallRunQuery.normal` at the instant the claim was accepted, stored
	-- once and never re-read live, same "locked at Entry" rule the client's
	-- own `WallRunState` follows. Compared against the LIVE `wallRunQuery`
	-- every Heartbeat (`Mirror.PassiveTransitions`) to detect a corner/curve
	-- exceeding `WallRunMaxNormalDeviationDegrees`.
	wallRunEntryNormal: Vector3?,
	-- The physical wall part itself (docs/MovementSystem.md §4.6/§5), same
	-- lazy-anchor timing as `wallRunEntryNormal` above (set on the SAME first
	-- post-entry `Mirror.PassiveTransitions` probe, never a claim-time forced
	-- one, for the identical rotation-lag reason). Snapshotted into
	-- `lastWallLeapWall` the instant a WallLeap launch is accepted, so the
	-- server knows which wall to block re-clinging onto.
	wallRunEntryInstance: BasePart?,
	-- Claim-buffering deadlines (2026-09-19 playtest fix, see
	-- `WallRunClaimBufferSeconds`'s own comment for the full root-cause
	-- reasoning) -- set the instant a "WallRun"/"WallLeap" claim is rejected
	-- for a reason that might just be replication catching up (still
	-- airborne / still wall-running, respectively), cleared the instant the
	-- buffered retry succeeds, is abandoned, or expires. `TraversalClaims.RetryBuffered`
	-- is the only reader; `TraversalClaims.OnClaim` is the only writer.
	pendingWallRunClaimUntil: number?,
	pendingWallLeapClaimUntil: number?,
	-- Sprint's own claim-buffering deadline (2026-09-21 "flagged switching
	-- Run->Sprint" investigation -- see `TransitionClaims.OnRequest`'s Sprint
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
	-- `TransitionClaims.RetryBufferedSprint` is the only reader; `TransitionClaims.OnRequest`
	-- is the only writer.
	pendingSprintClaimUntil: number?,
	-- Speed-sanity ceiling for a launch faster than the Airborne cap (WallLeap,
	-- playtest fix 2026-09-18; SlideJump, 2026-09-24). The launch speed
	-- doesn't decay on its own (Roblox applies no horizontal air drag), so the
	-- excess persists for the entire flight. An exact bound computed from
	-- server-known constants only (`TraversalMath.WallLeapMaxHorizontalSpeed`,
	-- audit M-003; `SpeedCaps.SlideCeiling` -- never the client's replicated velocity),
	-- consulted by `SpeedCaps.EffectiveMaxSpeed` until the flight ends: landing
	-- (server-verified), a wall, a ladder, water, or a vertical-ceiling
	-- correction. The descent check in `VerticalCeiling.Enforce` is what forces
	-- the flight to end (re-audit N-001): the character must fall once the
	-- arc tops out.
	airborneAllowedSpeed: number?,
	-- Set the first time the character is on real ground after the launch
	-- has topped out: the allowance lapses one landing grace later. The
	-- ceiling re-anchors on any support (see `VerticalCeiling.Enforce`), so
	-- without this a client that never reports landing could hop along the
	-- ground keeping a leap's speed forever.
	airborneAllowanceExpiresAt: number?,
	-- The fastest this slide can have started (2026-09-24 slide-jump
	-- rubber-band fix): the effective cap the server allowed just before the
	-- slide, scaled like the client's own entry and clamped to
	-- `SpeedCaps.SlideCeiling`. `Mirror.PassiveTransitions` times the slide's decay from it.
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
	-- `Probes.UpdateSlideGroundQuery` clears it the instant it isn't, so a stale
	-- normal from a slide that ended moments ago can never leak into
	-- `maxSpeedForState`'s cap for an unrelated state.
	slideGroundQuery: SpatialQueries.GroundQueryResult?,
	slideGroundQueryAt: number,
	-- WallCling's own probe (docs/MovementSystem.md §4.6/§8.4) -- the SAME
	-- `SpatialQueries.castClingWall` pure function the client calls, refreshed
	-- every Heartbeat while airborne (`Probes.UpdateWallClingQuery`, throttled off
	-- `WallClingRecheckInterval`, same cadence the client's own sustain-check
	-- uses) AND force-refreshed at claim time, same two-call-site pattern
	-- `wallRunQuery`/`Probes.UpdateWallRunQuery` already established. Consulted by
	-- `Mirror.PassiveTransitions`'s own WallCling branch as its independent
	-- "is the wall still really there" check -- deliberately added even
	-- though the plan's own §11.3 argued the speed ceiling alone was enough:
	-- `SpeedCheck.Enforce` only ever measures HORIZONTAL (X/Z) delta, so a
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
	-- OWN force-exit bookkeeping (`Mirror.PassiveTransitions`'s WallCling
	-- branch), never anything the client claims.
	wallClingLockoutUntil: number?,
	-- Per-cling flag mirroring the client's own `boostUsedThisCling` 1:1 --
	-- false on every accepted WallCling claim, true the instant a WallBoost
	-- claim is accepted; `CanEnter[WallBoost]` reads it via `Context.Build`.
	wallClingBoostUsed: boolean,
	-- Wall-leap memory, server side (docs/MovementSystem.md §4.6/§5) -- the
	-- server's OWN copy of `wallRunEntryInstance` at the instant a WallLeap
	-- launch was accepted, never anything the client asserts. Cleared on
	-- landing, same edge `peakHeight`/`airborneAllowedSpeed` already clear on,
	-- and on the first real touchdown after the leap even if the mirror never
	-- lands (same quick-hop capture as `doubleJumpLeftGround`, 2026-09-25: the
	-- client cleared it on a brief touchdown, the server didn't, and a wall run
	-- back onto that wall was refused and snapped down).
	lastWallLeapWall: BasePart?,
	-- Whether the support probe has seen the character off the ground since
	-- `lastWallLeapWall` was set; the next touchdown after that clears it.
	wallLeapLeftGround: boolean,
	-- WallBoost's own launch timestamp (docs/MovementSystem.md §8.4/§8.2)
	-- -- a DEDICATED field, not a reuse of the generic `traversalEntryAt`
	-- (unlike WallCling's own duration check, which does reuse it): the boost
	-- envelope has to keep being enforced for a while AFTER the mirror has
	-- already returned to Airborne (`SpeedCaps.EffectiveMaxSpeed`), the same
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
	-- `TraversalClaims.RetryBuffered` is the only reader; `TraversalClaims.OnClaim`
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
	-- Vault (docs/MovementSystem.md §4.8, §8.4). `ledgeQuery` is the server's
	-- own QueryLedge, taken only at claim time and on buffered retries (a
	-- vault has no sustain check to keep fresh).
	ledgeQuery: SpatialQueries.LedgeHit?,
	-- Server-owned cooldown clock: the accept time, moved back by however
	-- long the claim sat in the claim buffer (like `wallClingEnteredAt`).
	lastVaultAt: number?,
	-- Times the mirror's Vault window (`VaultDurationSeconds`).
	vaultStartedAt: number?,
	pendingVaultClaimUntil: number?,
	-- Until then, a ground anchor allows the vault's launch instead of only a
	-- jump: the mantle ends with the feet just above the ledge, so the launch
	-- leaves from ground the support probe can see (`VerticalCeiling.Anchor`).
	vaultLaunchUntil: number?,
	-- Recent root CFrames, a ring buffer written every Heartbeat
	-- (`Probes.RecordRootHistory`). The vault mantle moves the root onto the
	-- ledge, and those positions can replicate before the claim is judged; a
	-- probe of where the root was a moment earlier still finds the ledge.
	rootHistory: { CFrame },
	rootHistoryAt: { number },
	rootHistoryNext: number,
	-- A known horizontal move (the vault mantle's leg across) the speed window
	-- allows on top of its budget, for every window that starts by
	-- `displacementCreditUntil` (`SpeedCheck.CreditDisplacement`).
	displacementCredit: number,
	displacementCreditUntil: number?,
}

Sessions.ByPlayer = {} :: { [Player]: PlayerSession }

return Sessions
