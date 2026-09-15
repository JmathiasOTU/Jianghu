--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
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
-- (Zap enums are string unions, not Symbols) -- same lookup-table shape as
-- init.luau's NETWORK_CLAIM_NAMES, so a typo here fails to compile rather than
-- silently sending "Unknown" forever.
local DEBUG_STATE_NAMES: { [MovementState]: Network.DebugMovementState } = {
	[MovementStates.Idle] = "Idle",
	[MovementStates.Walk] = "Walk",
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
	[MovementStates.Airborne] = "Airborne",
	[MovementStates.CrouchIdle] = "CrouchIdle",
	[MovementStates.CrouchWalk] = "CrouchWalk",
	[MovementStates.Slide] = "Slide",
	[MovementStates.SlideJump] = "SlideJump",
	[MovementStates.DoubleJump] = "DoubleJump",
}

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
	-- Entry snapshot for DoubleJump's resimulation (TRAVERSAL-ROADMAP.md §7.1)
	-- -- this server's OWN `os.clock()` the instant it accepted the claim,
	-- never anything the client sends. `enforceDoubleJumpTrajectory` measures
	-- elapsed time from this, and `mirrorPassiveTransitions` uses it to decide
	-- when the mirror should hand back to Airborne on its own initiative.
	traversalEntryAt: number?,
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
-- no-op. Revisit with a real playtest capture, same as SpeedToleranceMultiplier
-- was.
local TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE = 15

-- Temporary instrumentation for the 2026-09-13 Sprint-rubber-banding
-- investigation (docs/MOVEMENT.md §5) -- prints real numbers instead of guessing
-- at a tolerance. Flip on for a playtest, off for normal play; left in (not
-- deleted) since Stage 2's WallRun/etc. validation will want the same kind of
-- capture again.
local SPEED_SANITY_DEBUG_LOGGING = false

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
		crouchHeld = session.crouchHeld,
		doubleJumpUsed = session.doubleJumpUsed,
		runDuration = runDuration,
		constants = constants,
	}
end

-- Landing target resolution, shared between the Airborne and DoubleJump
-- branches below (TRAVERSAL-ROADMAP.md §4) -- mirrors
-- `AirborneState.ResolveLandingTarget` client-side exactly, single source of
-- truth for "which grounded state does a landing input pattern resolve to"
-- rather than a second inline copy for DoubleJump's own mid-impulse-landing
-- case.
local function resolveLandingTarget(context: MovementContext): MovementState
	local hasInput = StateRules.HasMoveInput(context)
	if context.crouchHeld then
		return if hasInput then MovementStates.CrouchWalk else MovementStates.CrouchIdle
	elseif hasInput then
		return MovementStates.Walk
	end
	return MovementStates.Idle
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
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	if current == MovementStates.Airborne then
		if context.grounded then
			-- Landing while Ctrl is held goes to the crouch-variant instead of
			-- Idle/Walk (docs/MOVEMENT.md §9) -- a single-tick decision, same
			-- as AirborneState.Update's own client-side landing logic.
			if session.fsm:RequestTransition(resolveLandingTarget(context), context) then
				-- DoubleJump reset (TRAVERSAL-ROADMAP.md §4): mirrors the
				-- client's own reset on the identical "landed" edge.
				session.doubleJumpUsed = false
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
			if session.fsm:RequestTransition(resolveLandingTarget(context), context) then
				session.doubleJumpUsed = false
			end
			return
		end

		local elapsed = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
		if elapsed >= context.constants.DoubleJumpDecayDurationSeconds then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	if not context.grounded then
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
		local decayedSpeed =
			math.max(context.constants.CrouchSpeed, entrySpeed - context.constants.SlideDecayRate * elapsed)
		if decayedSpeed <= context.constants.CrouchSpeed then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context) then MovementStates.CrouchWalk else MovementStates.CrouchIdle,
				context
			)
		end
		return
	end

	if current == MovementStates.CrouchIdle then
		if not context.crouchHeld then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context) then MovementStates.Walk else MovementStates.Idle,
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
				if StateRules.HasMoveInput(context) then MovementStates.Walk else MovementStates.Idle,
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
-- CrouchSpeed, same "own dedicated tier" treatment as Walk/Run. Slide/
-- SlideJump cap at the SprintSpeed ceiling -- same reasoning as Airborne's
-- existing ceiling above: whatever tier was active before Sliding carries
-- through, and SlideJump's boost is clamped client-side to this same ceiling
-- (SlideJumpState.Enter) rather than needing a second cap here.
local function maxSpeedForState(state: MovementState, constants: EffectiveMovementConstants): number
	if state == MovementStates.Run then
		return constants.RunSpeed
	elseif
		state == MovementStates.Sprint
		or state == MovementStates.Airborne
		or state == MovementStates.Slide
		or state == MovementStates.SlideJump
		or state == MovementStates.DoubleJump
	then
		-- DoubleJump only ever touches vertical velocity (§2's
		-- vertical-only MaxAxesForce) -- horizontal speed carries through
		-- from whatever tier was active at takeoff, same "ceiling, not a
		-- guessed tier" reasoning Airborne already uses.
		return constants.SprintSpeed
	elseif state == MovementStates.CrouchIdle or state == MovementStates.CrouchWalk then
		return constants.CrouchSpeed
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
local function effectiveMaxSpeed(session: PlayerSession, constants: EffectiveMovementConstants): number
	local currentCap = maxSpeedForState(session.fsm.current, constants)
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
		traversalEntryAt = nil,
		speedSanitySuspendedUntil = nil,
		traversalRateLimiter = RateLimiter.new(TRAVERSAL_CLAIMS_PER_SECOND, 1),
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
	local maxDistance = effectiveMaxSpeed(session, constants) * elapsed * constants.SpeedToleranceMultiplier

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
local function enforceDoubleJumpTrajectory(session: PlayerSession, constants: EffectiveMovementConstants)
	if session.fsm.current ~= MovementStates.DoubleJump or not session.traversalEntryAt then
		return
	end

	local elapsed = os.clock() - (session.traversalEntryAt :: number)
	local expected =
		TraversalMath.DoubleJumpVerticalVelocity(elapsed, constants.DoubleJumpForce, constants.DoubleJumpDecayDurationSeconds)
	local actual = session.rootPart.AssemblyLinearVelocity.Y

	if actual > expected + TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE then
		local velocity = session.rootPart.AssemblyLinearVelocity
		session.rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, expected, velocity.Z)
	end
end

-- The real exploit surface for the new traversal moves (TRAVERSAL-ROADMAP.md
-- §6/§7): a modified client could claim DoubleJump without ever earning it
-- (already airborne, air-jump not yet spent). Legality is checked the same
-- way as every other claim in this file -- against this session's OWN
-- mirrored FSM/context, never anything the client asserts.
local function onClaimTraversalMove(player: Player, claim: Network.ClaimableTraversalMove)
	local session = sessions[player]
	if not session then
		return
	end

	if not session.traversalRateLimiter:tryAcquire() then
		return
	end

	-- Only "DoubleJump" exists yet (Phase 1) -- Dash/WallRun/WallClimb/Vault
	-- get their own branches here as their own phases land.
	local claimedState = if claim == "DoubleJump" then MovementStates.DoubleJump else nil
	if not claimedState then
		return
	end

	local context = buildContext(session)
	if session.fsm:RequestTransition(claimedState, context) then
		session.doubleJumpUsed = true
		session.traversalEntryAt = os.clock()

		-- Exemption window (TRAVERSAL-ROADMAP.md §7.4, shipped alongside
		-- Phase 1 per the roadmap's own risk register -- without it, this
		-- move's residual momentum on landing would immediately rubber-band
		-- against `enforceSpeedSanity`'s cap for the tier it's landing into).
		session.speedCheckPosition = session.rootPart.Position
		session.speedCheckAt = os.clock()
		session.speedSanitySuspendedUntil = os.clock() + MovementConstants.TraversalSpeedSanityGraceSeconds
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

	if not session.rateLimiter:tryAcquire() then
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
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = buildContext(session)

	if session.fsm:RequestTransition(claimedState, context) then
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

	RunService.Heartbeat:Connect(function()
		for _, session in sessions do
			local constants = MovementTuningState.GetEffective(session.player)
			mirrorPassiveTransitions(session)
			enforceSpeedSanity(session, constants)
			enforceDoubleJumpTrajectory(session, constants)
			broadcastDebugState(session)
		end
	end)
end

return MovementValidationService
