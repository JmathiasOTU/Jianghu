--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)
local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local CharacterMover = require(script.CharacterMover)
local InputController = require(script.InputController)
local ClientMovementContextModule = require(script.ClientMovementContext)
local DebugSnapshot = require(script.DebugSnapshot)
local TuningSnapshot = require(script.TuningSnapshot)
local NoclipController = require(script.NoclipController)
local Network = require(script.Parent.Parent.Network.network)

local FacingController = require(script.Presentation.FacingController)
local LocomotionAnimator = require(script.Presentation.LocomotionAnimator)

local IdleState = require(script.States.IdleState)
local WalkState = require(script.States.WalkState)
local RunState = require(script.States.RunState)
local SprintState = require(script.States.SprintState)
local AirborneState = require(script.States.AirborneState)
local CrouchIdleState = require(script.States.CrouchIdleState)
local CrouchWalkState = require(script.States.CrouchWalkState)
local SlideState = require(script.States.SlideState)
local SlideJumpState = require(script.States.SlideJumpState)
local DoubleJumpState = require(script.States.DoubleJumpState)
local HardLandingState = require(script.States.HardLandingState)
local WallRunState = require(script.States.WallRunState)
local WallLeapState = require(script.States.WallLeapState)
local WallClingState = require(script.States.WallClingState)
local WallBoostState = require(script.States.WallBoostState)

type MovementState = MovementStates.MovementState
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- This folder syncs as a single ModuleScript via init.luau (not a flat
-- MovementController.luau) specifically so InputController/CharacterMover/States
-- can live as real children reachable via `script.X` -- ClientBootstrap's
-- Loader.LoadChildren(Controllers) only requires DIRECT children of Controllers,
-- never descendants, so anything placed flat under a `Controllers/Movement/`
-- subfolder without this init.luau trick would silently never get Init'd.
local MovementController = {}

local States = {
	[MovementStates.Idle] = IdleState,
	[MovementStates.Walk] = WalkState,
	[MovementStates.Run] = RunState,
	[MovementStates.Sprint] = SprintState,
	[MovementStates.Airborne] = AirborneState,
	[MovementStates.CrouchIdle] = CrouchIdleState,
	[MovementStates.CrouchWalk] = CrouchWalkState,
	[MovementStates.Slide] = SlideState,
	[MovementStates.SlideJump] = SlideJumpState,
	[MovementStates.DoubleJump] = DoubleJumpState,
	[MovementStates.HardLanding] = HardLandingState,
	[MovementStates.WallRun] = WallRunState,
	[MovementStates.WallLeap] = WallLeapState,
	[MovementStates.WallCling] = WallClingState,
	[MovementStates.WallBoost] = WallBoostState,
}

-- Only Run/Sprint are earned, exploit-relevant transitions that need a server
-- claim naming the target STATE (see docs/MOVEMENT.md §5) -- Idle/Walk/Airborne
-- need no remote. Crouch/Slide (docs/MOVEMENT.md §9) are claimed differently
-- -- see the `input.CrouchChanged` connection below -- so they're deliberately
-- NOT added here: unlike Run/Sprint, the client never claims "CrouchIdle"/
-- "CrouchWalk"/"Slide" by name, it only tells the server whether Ctrl is held
-- and lets mirrorPassiveTransitions derive the rest, the same way it already
-- derives Idle<->Walk.
local NETWORK_CLAIM_NAMES: { [MovementState]: "Run" | "Sprint" } = {
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
}

-- Symbol -> plain string name for the F4 debug overlay's DebugSnapshot
-- (docs/MOVEMENT.md) and the server's `MovementDebugState` broadcast -- see
-- Shared/FSM/MovementStateNames.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- server's own DEBUG_STATE_NAMES).
local DEBUG_STATE_NAMES = MovementStateNames.DebugNames

-- Grounded-family states (TRAVERSAL-ROADMAP.md §4) -- landing into any of
-- these is what resets `doubleJumpUsed` back to available, mirrored 1:1 by
-- MovementValidationService's own PlayerSession. See
-- Shared/FSM/MovementStateGroups.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- server's own GROUNDED_STATES) for why this is a plain set, not derived
-- from StateRules.Transitions.
local GROUNDED_STATES = MovementStateGroups.Grounded

-- How often the current Run/Sprint claim is re-sent while held, not just on the
-- transition edge (found 2026-09-13, docs/MOVEMENT.md §5: real playtest logs
-- showed the server mirror stuck at Run while the player was genuinely sprinting
-- the whole time). The claim fires once on `fsm.changed`, fire-and-forget with no
-- ack -- if that single packet is ever rejected (e.g. the dwell reads a hair under
-- threshold due to ordinary jitter right at the 3s boundary) or dropped, the
-- client's own FSM is already in Sprint and never transitions again, so it never
-- naturally resends. Periodic reassertion makes that self-healing: a `RequestTransition`
-- for the state the FSM mirror is already in is a harmless no-op server-side
-- (`next == current` fails legality trivially), so this only ever repairs a
-- desync, never causes one. A network-reliability concern, not gameplay tuning --
-- lives here rather than MovementConstants for the same reason
-- TRANSITION_CLAIMS_PER_SECOND lives in MovementValidationService instead of
-- there.
local CLAIM_RESYNC_INTERVAL_SECONDS = 1

-- Temporary capture switch for testing QueryWallRun in isolation (Wall Run &
-- Leap Mechanic Guideline §1, Part 1) -- off by default, same
-- flip-on-for-a-playtest pattern as MovementValidationService's
-- SPEED_SANITY_DEBUG_LOGGING. Prints only on a hit/miss/side CHANGE, not every
-- probe, so it's readable while walking the character along a wall in Studio.
local WALLRUN_DEBUG_LOGGING = false

-- Temporary diagnostic capture for the 2026-09-19 "WallCling never triggers"
-- playtest report -- traces the JumpRequested unified handler's own path
-- (grounded state, whether WallRun/WallCling/DoubleJump each accepted or
-- rejected). Root cause confirmed via a real capture (see
-- SpatialQueries.WALLCLING_DEBUG_LOGGING's own comment): the test wall wasn't
-- Anchored, not a code bug. Off by default now that it's confirmed.
local WALLCLING_TRACE_LOGGING = false

local input: InputController.InputController

local function setupCharacter(character: Model, lifeTrove: Trove.Trove)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local characterMover =
		lifeTrove:Add(CharacterMover.new(humanoid, TuningSnapshot.Get().JumpPower))
	local noclip = lifeTrove:Add(NoclipController.new(humanoid, rootPart, input))
	local fsm = lifeTrove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)

	-- Presentation: purely cosmetic, never touched by states or the FSM (they only
	-- read it) -- docs/MOVEMENT.md §3/§4 -- except WallRunState's own
	-- `SetLockDirection` escape hatch (guideline §3, playtest fix 2026-09-18),
	-- reached via `buildContext`'s `facingController` field below like every
	-- other client-only accessor.
	local facingController = lifeTrove:Add(FacingController.new(humanoid, rootPart))
	lifeTrove:Add(
		LocomotionAnimator.new(
			humanoid,
			rootPart,
			fsm,
			input,
			characterMover,
			WallRunState.GetEntrySide,
			AirborneState.GetLastLandingWasMedium
		)
	)

	-- Live tuning (docs/MOVEMENT.md §8): pushes the server's effective-constants
	-- broadcast into TuningSnapshot and re-applies JumpPower immediately, since
	-- unlike WalkSpeed/RunSpeed/SprintSpeed (only ever set on a state's own
	-- Enter), JumpPower has no per-frame/per-transition write site of its own to
	-- naturally pick up a changed value.
	lifeTrove:Add(Network.TuningState.SetCallback(function(value)
		TuningSnapshot.Set({
			RunDoubleTapWindowSeconds = value.runDoubleTapWindowSeconds,
			SprintThresholdSeconds = value.sprintThresholdSeconds,
			WalkSpeed = value.walkSpeed,
			RunSpeed = value.runSpeed,
			SprintSpeed = value.sprintSpeed,
			JumpPower = value.jumpPower,
			SprintForwardDeadzone = value.sprintForwardDeadzone,
			SpeedToleranceMultiplier = value.speedToleranceMultiplier,
			CrouchSpeed = value.crouchSpeed,
			SlideDecayRate = value.slideDecayRate,
			SlideEntrySpeedMultiplier = value.slideEntrySpeedMultiplier,
			SlideJumpBoostAmount = value.slideJumpBoostAmount,
			AnimationFadeTimeSeconds = value.animationFadeTimeSeconds,
			LandingAnimationHoldSeconds = value.landingAnimationHoldSeconds,
			HardLandingHeightThreshold = value.hardLandingHeightThreshold,
			HardLandingDurationSeconds = value.hardLandingDurationSeconds,
			MediumLandingHeightThreshold = value.mediumLandingHeightThreshold,
			MediumLandingDurationSeconds = value.mediumLandingDurationSeconds,
			MediumLandingSpeedMultiplier = value.mediumLandingSpeedMultiplier,
			DoubleJumpForce = value.doubleJumpForce,
			DoubleJumpDecayDurationSeconds = value.doubleJumpDecayDurationSeconds,
			SlideSlopeAngleThresholdDegrees = value.slideSlopeAngleThresholdDegrees,
			SlideMaxWalkableSlopeDegrees = value.slideMaxWalkableSlopeDegrees,
			SlideSlopeAmplificationCap = value.slideSlopeAmplificationCap,
			SlideGroundRaycastThrottleSeconds = value.slideGroundRaycastThrottleSeconds,
			WallRunMinEntrySpeed = value.wallRunMinEntrySpeed,
			WallRunEntryDotThreshold = value.wallRunEntryDotThreshold,
			WallRunSpeed = value.wallRunSpeed,
			WallRunSinkSpeed = value.wallRunSinkSpeed,
			WallRunClingDistance = value.wallRunClingDistance,
			WallRunClingCorrectionRate = value.wallRunClingCorrectionRate,
			WallRunClingMaxCorrectionSpeed = value.wallRunClingMaxCorrectionSpeed,
			WallRunMaxNormalDeviationDegrees = value.wallRunMaxNormalDeviationDegrees,
			WallRunMaxDurationSeconds = value.wallRunMaxDurationSeconds,
			WallLeapBurstForce = value.wallLeapBurstForce,
			WallLeapPushForce = value.wallLeapPushForce,
			WallLeapUpwardForce = value.wallLeapUpwardForce,
			WallClingMaxDuration = value.wallClingMaxDuration,
			WallClingMaxFacingAngleDegrees = value.wallClingMaxFacingAngleDegrees,
			WallClingDropInputThreshold = value.wallClingDropInputThreshold,
			WallClingTimeoutLockout = value.wallClingTimeoutLockout,
			WallClingDropLockout = value.wallClingDropLockout,
			WallClingPostBoostCooldown = value.wallClingPostBoostCooldown,
			WallBoostUpwardForce = value.wallBoostUpwardForce,
			WallBoostSeparationSpeed = value.wallBoostSeparationSpeed,
			WallBoostStateDuration = value.wallBoostStateDuration,
		})
		characterMover:SetJumpPower(value.jumpPower)
	end))

	-- Noclip/fly (docs/MOVEMENT.md §8): the server is the sole authority on
	-- whether this session is noclipping (Server/State/NoclipState.luau) --
	-- this callback is what lets the local NoclipController actually start/stop
	-- driving the character once the server confirms the toggle, never a
	-- client-side guess ahead of that confirmation.
	local noclipActive = false
	lifeTrove:Add(Network.NoclipState.SetCallback(function(enabled: boolean)
		noclipActive = enabled
		noclip:SetActive(enabled)
	end))

	-- Per-life flag, not derivable from Humanoid replication
	-- (TRAVERSAL-ROADMAP.md §4) -- same "owned by the FSM lifecycle, not any
	-- one state module" treatment as `noclipActive`/the claim-resync
	-- timestamps below, since both DoubleJump (consumes it) and the landing
	-- edge (resets it) need to touch it without requiring each other.
	local doubleJumpUsed = false

	-- Crouch-lock (SlideJump landing fix): true from the instant SlideJump is
	-- entered until Ctrl is actually released, regardless of how long that
	-- takes -- masked into `crouchHeld` below so every existing "if
	-- crouchHeld, go crouch/slide" check (IdleState/WalkState/RunState/
	-- SprintState's own Update, AirborneState.ResolveLandingTarget) treats a
	-- still-held Ctrl as not-held without any of them needing to know why.
	-- Without this, a player who slide-jumps without ever releasing Ctrl (the
	-- common case -- jump is a different key) would resolve the landing to
	-- Idle/Walk correctly, only for THAT state's own next Update tick to see
	-- `crouchHeld` still true and immediately re-enter CrouchIdle/CrouchWalk
	-- -- the exact "lands in idle, then instantly crouches" two-hop this
	-- fixes. Cleared on the real key-up edge (`input.CrouchChanged` below),
	-- never on a timer, so a legitimate re-press after release still works
	-- immediately.
	local crouchSuppressed = false

	-- Landing-resume fix: Run/Sprint if that's the tier this life was in the
	-- instant it left the ground, nil otherwise -- set on the Run/Sprint ->
	-- Airborne edge below, carried through an Airborne<->DoubleJump hop,
	-- cleared the instant a landing actually resolves (also below). Read by
	-- `AirborneState.ResolveLandingTarget` (via `buildContext` below) to land
	-- straight back into the same tier when forward is still held, and by
	-- `StateRules.CanEnter[Sprint]` to admit that resume without re-checking a
	-- dwell timer that `fsm.current == Airborne` has no way to satisfy.
	local preAirborneLocomotion: MovementState? = nil

	-- HardLanding fall-height tracking (docs/MOVEMENT.md §10 rework): the peak
	-- `rootPart.Position.Y` reached since this life last left the ground, nil
	-- while grounded (no excursion in progress). Grown every Heartbeat below
	-- (grow-only -- never reset there, to avoid a same-frame race against the
	-- landing decision that reads it, see the Heartbeat comment); seeded to
	-- the current height on the real takeoff edge and cleared the instant a
	-- landing resolves, both in the `fsm.changed` handler below, mirroring
	-- `preAirborneLocomotion`'s own bookkeeping shape. Read via `buildContext`
	-- as `fallHeight` (peak minus CURRENT height) by `AirborneState.
	-- ResolveLandingTarget` to decide whether a landing forces `HardLanding`.
	local peakHeight: number? = nil

	-- WallRun's own throttled side-cast (Wall Run & Leap Mechanic Guideline
	-- §1): only probed while airborne, cleared immediately on grounding,
	-- re-fired via a dt-accumulator rather than every Heartbeat
	-- (ARCHITECTURE.md §6). `wallRunQueryLastLogged` only feeds the debug
	-- print below, never gameplay.
	local wallRunQuery: SpatialQueries.WallRunQueryResult? = nil
	local wallRunQueryAccumulatedDt = 0
	local wallRunQueryLastLogged: SpatialQueries.WallRunQueryResult? = nil
	local wallRunCanEnterLastLogged = false

	-- WallCling's own probe (docs/WallClimbingPlan.md §7): forced-fresh only
	-- at the JumpRequested instant (see that connection below), NOT refreshed
	-- continuously every Heartbeat like `wallRunQuery` -- the cling gesture is
	-- a single key press plus a facing check, not a sustained directional
	-- hold, so there's no need to keep probing while nothing is attempting to
	-- enter. WallClingState's own ongoing sustain-recheck calls
	-- `characterMover:QueryClingWall()` directly instead of reading this.
	local wallClingQuery: SpatialQueries.ClingWallHit? = nil

	-- Wall-leap memory (docs/WallClimbingPlan.md §2/§9): the physical wall
	-- part this life most recently wall-leapt from, nil otherwise -- set on
	-- the WallRun -> WallLeap edge below (off `context.wallRunEntryInstance`,
	-- captured BEFORE WallRunState.Exit nils its own copy), cleared the
	-- instant this life lands. Read by `StateRules.CanEnter[WallCling]` via
	-- `buildContext` to block re-clinging to the wall just abandoned.
	local lastWallLeapWall: BasePart? = nil

	local function buildContext(): ClientMovementContext
		local runDuration = if fsm.current == MovementStates.Run
			then RunState.GetDuration()
			else nil
		return {
			moveIntent = input:GetMoveIntent(),
			grounded = characterMover:IsGrounded(),
			jumping = characterMover:IsJumping(),
			crouchHeld = input:IsCrouchHeld() and not crouchSuppressed,
			doubleJumpUsed = doubleJumpUsed,
			runDuration = runDuration,
			preAirborneLocomotion = preAirborneLocomotion,
			fallHeight = if peakHeight then peakHeight - rootPart.Position.Y else nil,
			horizontalVelocity = characterMover:GetHorizontalVelocity(),
			wallRunQuery = wallRunQuery,
			wallClingQuery = wallClingQuery,
			facingDirection = characterMover:GetFacingDirection(),
			wallClingLockoutUntil = WallClingState.GetLockoutUntil(),
			wallClingBoostUsed = WallClingState.GetBoostUsed(),
			wallClingNormal = WallClingState.GetNormal(),
			lastWallLeapWall = lastWallLeapWall,
			-- Still an open design decision (TRAVERSAL-ROADMAP.md §0/§3) --
			-- "always available" until a real Qinggong/stamina resource
			-- exists, same placeholder both sides use.
			qinggong = math.huge,
			-- Landing-resume fix, hardened 2026-09-18 (see MovementTypes.luau's
			-- own field comment) -- read off `humanoid.AutoRotate` rather than
			-- `UserInputService.MouseBehavior` directly so this agrees with
			-- whatever the SERVER sees off the same replicated property,
			-- never a client-only signal the server has no way to check.
			cameraLocked = not humanoid.AutoRotate,
			constants = TuningSnapshot.Get(),
			characterMover = characterMover,
			facingController = facingController,
			fsm = fsm,
			slideSpeed = SlideState.GetCurrentSpeed(),
			slideDirection = SlideState.GetCurrentDirection(),
			wallRunEntryNormal = WallRunState.GetEntryNormal(),
			wallRunEntryTangent = WallRunState.GetEntryTangent(),
			wallRunEntryInstance = WallRunState.GetEntryInstance(),
		}
	end

	-- The FSM starts already in Idle, so no `changed` fires for it -- Enter has to
	-- run once up front to stay symmetric with every later transition.
	IdleState.Enter(buildContext())
	CollisionGroups.Apply(character, MovementStates.Idle)

	local lastClaimResyncAt = 0
	local lastCrouchResyncAt = 0

	local function fireClaim(claimName: "Run" | "Sprint")
		Network.RequestMovementTransition.Fire(claimName)
		DebugSnapshot.RecordClaim(claimName)
		lastClaimResyncAt = os.clock()
	end

	lifeTrove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		-- ONE shared context for both calls (bug found alongside
		-- TRAVERSAL-ROADMAP.md §8 Phase 3) -- building a SECOND, fresh context
		-- for Enter after Exit already ran silently broke any "outgoing
		-- state's own value, read via context" hand-off (e.g. `slideSpeed`/
		-- `slideDirection`, ClientMovementContext.luau): SlideState.Exit
		-- nulls its module-scope currentSpeed/currentDirection, so a second
		-- buildContext() call afterward would always see them as nil, and
		-- SlideJumpState.Enter would silently fall back to CrouchSpeed/zero
		-- instead of the real decayed slide velocity. Nothing between Exit
		-- and Enter here yields or mutates any of `buildContext`'s own live
		-- sources (input/characterMover/constants), so reusing one context
		-- for both is safe -- Exit only ever mutates the FROM state's own
		-- module-local variables, never the context table itself.
		local context = buildContext()
		States[previous].Exit(context)

		-- F4 debug overlay state history (docs/MOVEMENT.md §8): recorded
		-- BEFORE `Enter` below, not after (fixed 2026-09-18, external audit
		-- finding) -- `WallLeapState`/`SlideJumpState`'s own `Enter` calls
		-- `RequestTransition` synchronously, reentrantly firing THIS SAME
		-- `fsm.changed` handler for their own hand-off to Airborne before this
		-- call even returns. Recording AFTER `Enter` meant the reentrant
		-- inner transition's own `RecordTransition` call landed first,
		-- scrambling the history's real chronological order (e.g. showing
		-- "WallLeap" as more recent than the "Airborne" it actually leads
		-- into). `RecordTransition` only appends a string to a list -- it
		-- reads nothing off `context` and has no dependency on `Enter` having
		-- run first, so moving it earlier is free.
		DebugSnapshot.RecordTransition(DEBUG_STATE_NAMES[next])

		States[next].Enter(context)

		-- Passability (docs/MOVEMENT.md §9): switched on every transition, not
		-- gated on "did the group actually change" -- cheap enough, and
		-- CollisionGroups.Apply itself just re-derives the same group name for
		-- non-crouch states, so a redundant write here is harmless.
		CollisionGroups.Apply(character, next)

		local claimName = NETWORK_CLAIM_NAMES[next]
		if claimName then
			fireClaim(claimName)
		end

		-- DoubleJump bookkeeping (TRAVERSAL-ROADMAP.md §4): consumed the
		-- instant it's entered, reset the instant the character actually
		-- lands -- checked as two separate branches (not "next == DoubleJump
		-- else GROUNDED_STATES[next]") since landing can happen directly from
		-- Airborne without ever touching DoubleJump this life.
		--
		-- WallRun/WallLeap claims (Wall Run & Leap Mechanic Guideline §6):
		-- fired the same fire-and-forget way DoubleJump's already is, AFTER
		-- `States[next].Enter` above has already applied this life's own
		-- client-predicted physics -- the server's own `onClaimTraversalMove`
		-- resimulates legality independently off its own `wallRunQuery`/
		-- `GetHorizontalVelocity`, never trusting this claim's mere arrival.
		-- Neither touches `doubleJumpUsed` -- only an actual landing does,
		-- same as every other airborne-family entry.
		if next == MovementStates.DoubleJump then
			doubleJumpUsed = true
			Network.ClaimTraversalMove.Fire("DoubleJump")
		elseif next == MovementStates.WallRun then
			Network.ClaimTraversalMove.Fire("WallRun")
		elseif next == MovementStates.WallLeap then
			Network.ClaimTraversalMove.Fire("WallLeap")
			-- Wall-leap memory (docs/WallClimbingPlan.md §2/§9): snapshot off
			-- `context.wallRunEntryInstance`, captured by `buildContext()`
			-- above BEFORE `States[WallRun].Exit(context)` ran and nilled
			-- WallRunState's own copy -- reading `WallRunState.
			-- GetEntryInstance()` directly here instead would already be nil.
			lastWallLeapWall = context.wallRunEntryInstance
		elseif next == MovementStates.WallCling then
			Network.ClaimTraversalMove.Fire("WallCling")
		elseif next == MovementStates.WallBoost then
			Network.ClaimTraversalMove.Fire("WallBoost")
		elseif GROUNDED_STATES[next] then
			doubleJumpUsed = false
			-- Cleared on landing (docs/WallClimbingPlan.md assumption 5) --
			-- touching a DIFFERENT wall needs no separate clear, since
			-- `CanEnter[WallCling]`'s own check is instance equality against
			-- whatever wall is actually being clung to right now.
			lastWallLeapWall = nil
		end

		-- Crouch-lock (SlideJump landing fix): armed the instant SlideJump is
		-- entered -- see the `crouchSuppressed` declaration above for why this
		-- has to persist past the landing edge, not just the one frame.
		if next == MovementStates.SlideJump then
			crouchSuppressed = true
		end

		-- Landing-resume bookkeeping (landing-resume fix): mirrors the
		-- DoubleJump bookkeeping's own two-branch shape just above -- set on
		-- the Run/Sprint -> Airborne edge, left untouched on every OTHER edge
		-- into Airborne/DoubleJump so it survives an Airborne <-> DoubleJump
		-- hop (`previous` there is Airborne/DoubleJump itself, neither of
		-- which is Run/Sprint, so the branch below correctly no-ops and keeps
		-- whatever was already set). Slide -> SlideJump -> Airborne never sets
		-- it at all (`previous` there is SlideJump), so a slide-jump always
		-- lands via the normal Walk/Idle path, never a resumed Run/Sprint --
		-- deliberately out of scope for this fix. Cleared the instant a
		-- landing actually resolves, below.
		if next == MovementStates.Airborne or next == MovementStates.DoubleJump then
			if previous == MovementStates.Run or previous == MovementStates.Sprint then
				preAirborneLocomotion = previous
			end
		elseif GROUNDED_STATES[next] then
			preAirborneLocomotion = nil
		end

		-- HardLanding fall-height bookkeeping (docs/MOVEMENT.md §10 rework):
		-- seeded on the real takeoff edge -- `next == Airborne` covers every
		-- grounded-state jump-off AND Slide -> SlideJump -> Airborne (`previous`
		-- there is SlideJump); excluded when `previous` is DoubleJump, WallRun,
		-- WallLeap, WallCling, or WallBoost so none of those hops back to
		-- Airborne resets the peak mid-excursion (found while wiring WallRun
		-- into this same edge -- each is still the same continuous excursion,
		-- exactly like the DoubleJump hop already correctly treated it --
		-- WallCling/WallBoost need the identical exclusion: clinging or
		-- boosting partway down a long fall is still the same excursion, not
		-- a fresh one, docs/WallClimbingPlan.md §12).
		-- Cleared the instant a landing actually resolves, same edge as
		-- `preAirborneLocomotion` just above.
		if next == MovementStates.Airborne then
			if
				previous ~= MovementStates.DoubleJump
				and previous ~= MovementStates.WallRun
				and previous ~= MovementStates.WallLeap
				and previous ~= MovementStates.WallCling
				and previous ~= MovementStates.WallBoost
			then
				peakHeight = rootPart.Position.Y
			end
		elseif GROUNDED_STATES[next] then
			peakHeight = nil
		end
	end)

	lifeTrove:Connect(input.RunRequested, function()
		fsm:RequestTransition(MovementStates.Run, buildContext())
	end)

	-- WallBoost (docs/WallClimbingPlan.md §2/§10.1 step 5): routed through
	-- WallClingState.RequestBoostTransition, not a raw fsm:RequestTransition,
	-- so the `Boosted` exit reason is correctly tagged for
	-- WallClingPostBoostCooldown -- same "external input event -> plain
	-- request" shape as input.RunRequested above, a harmless no-op via
	-- CanEnter[WallBoost]/topology if not currently clinging or already
	-- boosted this cling.
	lifeTrove:Connect(input.BoostRequested, function()
		WallClingState.RequestBoostTransition(buildContext())
	end)

	-- Unified jump-action priority handler (Wall Run & Leap Mechanic Guideline
	-- §2/§5): WallRun is attempted BEFORE DoubleJump on the same press -- the
	-- stricter, more deliberate gesture wins when both are legal, same
	-- priority idiom the pre-revert design used for WallClimb vs. WallRun.
	-- Falls through to today's unchanged DoubleJump attempt when
	-- CanEnter[WallRun] fails (no wall, wrong angle, too slow) -- a player
	-- with no wall nearby sees no behavior change. Fires on EVERY jump-action
	-- request regardless of grounded state (see InputController.JumpRequested's
	-- own doc comment for why that has to be the signal); no explicit
	-- "currently Airborne"/"currently WallRun" guard needed for the DoubleJump
	-- branch, same reasoning as SlideJump's own CanEnter comment -- topology
	-- alone already makes it a no-op unless legally reachable.
	--
	-- A third press while already wall-running fires WallLeap directly
	-- (guideline §4) -- a plain RequestTransition, same as every other edge;
	-- no CanEnter[WallLeap] exists so topology alone gates it (see
	-- StateRules.luau's own comment on that edge). WallLeapState.Enter does
	-- the actual launch-impulse work and immediately hands off to Airborne in
	-- the same synchronous call, the identical one-tick shape SlideJump
	-- already established -- checked FIRST here so "the press that entered
	-- WallRun" and "the press that leaps out of it" can never be the same
	-- press.
	lifeTrove:Connect(input.JumpRequested, function()
		-- Force a fresh probe here rather than reusing the throttled Heartbeat
		-- cache -- same staleness fix as the server's `updateWallRunQuery(session, true)`.
		local probed = fsm.current ~= MovementStates.WallRun and not characterMover:IsGrounded()
		if probed then
			wallRunQuery = characterMover:QueryWallRun()
			wallRunQueryAccumulatedDt = 0
			wallClingQuery = characterMover:QueryClingWall()
		end
		if WALLCLING_TRACE_LOGGING then
			print(
				string.format(
					"[WallClingTrace] JumpRequested fsm=%s grounded=%s probed=%s wallClingQuery=%s",
					tostring(fsm.current),
					tostring(characterMover:IsGrounded()),
					tostring(probed),
					tostring(wallClingQuery ~= nil)
				)
			)
		end
		local context = buildContext()
		if fsm.current == MovementStates.WallRun then
			fsm:RequestTransition(MovementStates.WallLeap, context)
			return
		end
		if fsm:RequestTransition(MovementStates.WallRun, context) then
			return
		end
		-- WallCling (docs/WallClimbingPlan.md §2/§3): tried before the
		-- DoubleJump fallback so a valid clingable wall always wins over
		-- spending the midair jump (assumption 1) -- the double jump is never
		-- consumed unless THIS attempt itself fails. Head-on facing
		-- (WallCling) and side-on alignment (WallRun, already tried above)
		-- are mutually exclusive by their own angle gates, so this never
		-- races WallRun for the same press.
		local clingAccepted = fsm:RequestTransition(MovementStates.WallCling, context)
		if WALLCLING_TRACE_LOGGING then
			print(
				string.format(
					"[WallClingTrace] WallCling RequestTransition -> %s",
					tostring(clingAccepted)
				)
			)
		end
		if clingAccepted then
			return
		end
		fsm:RequestTransition(MovementStates.DoubleJump, context)
	end)

	-- Crouch/Slide claim (docs/MOVEMENT.md §9): unlike Run/Sprint's claims
	-- (which name the target FSM state), this only ever tells the server
	-- whether Ctrl is held -- fired on the raw key edge, not on any FSM
	-- transition, specifically so a Ctrl-press mid-air (anticipating a
	-- crouched landing) reaches the server before the landing decision has to
	-- be made, not after.
	lifeTrove:Connect(input.CrouchChanged, function(held: boolean)
		Network.RequestMovementTransition.Fire(if held then "CrouchDown" else "CrouchUp")
		lastCrouchResyncAt = os.clock()
		-- Crouch-lock re-arm (SlideJump landing fix): the real key-up edge is
		-- the only thing that clears the lock -- a legitimate re-press right
		-- after release must work immediately, never gated on a cooldown.
		if not held then
			crouchSuppressed = false
		end
	end)

	lifeTrove:Connect(RunService.Heartbeat, function(dt: number)
		-- Grow-only, deliberately BEFORE `Update` below (docs/MOVEMENT.md §10
		-- rework): on the exact landing Heartbeat, `characterMover:IsGrounded()`
		-- has already flipped true by the time this runs, same instant
		-- `AirborneState.Update` reads `context.grounded` to make its landing
		-- decision -- if this reset `peakHeight` on that same "now grounded"
		-- read, `fallHeight` would already be ~0 by the time `ResolveLandingTarget`
		-- consults it a few lines later in the SAME frame. Resetting is left
		-- entirely to the `fsm.changed` handler above instead, which only fires
		-- (synchronously, within `Update`'s own `RequestTransition` call) AFTER
		-- the landing decision has already consumed the real peak.
		if peakHeight then
			peakHeight = math.max(peakHeight, rootPart.Position.Y)
		end

		-- WallRun side-cast throttle (Wall Run & Leap Mechanic Guideline §1):
		-- only while airborne, cleared the instant grounded, re-fired on its
		-- own dt-accumulator cadence rather than raw per-tick.
		if characterMover:IsGrounded() then
			wallRunQuery = nil
			wallRunQueryAccumulatedDt = 0
		else
			wallRunQueryAccumulatedDt += dt
			if wallRunQueryAccumulatedDt >= MovementConstants.WallRunQueryThrottleSeconds then
				wallRunQueryAccumulatedDt = 0
				wallRunQuery = characterMover:QueryWallRun()
			end
		end

		if WALLRUN_DEBUG_LOGGING and wallRunQuery ~= wallRunQueryLastLogged then
			wallRunQueryLastLogged = wallRunQuery
			if wallRunQuery then
				print(
					string.format(
						"[WallRunQuery] side=%s normal=%s",
						wallRunQuery.side,
						tostring(wallRunQuery.normal)
					)
				)
			else
				print("[WallRunQuery] no wall")
			end
		end

		-- CanEnter[WallRun] observability (Wall Run & Leap Mechanic Guideline
		-- §2, Part 2) -- evaluated directly here rather than through
		-- fsm:RequestTransition, since there's no Transitions edge into WallRun
		-- yet (that's §5's job); this only confirms the four-gate predicate
		-- itself is reading real context correctly, no state change happens.
		if WALLRUN_DEBUG_LOGGING then
			local debugContext = buildContext()
			local canEnter = StateRules.CanEnter[MovementStates.WallRun](debugContext)
			if canEnter ~= wallRunCanEnterLastLogged then
				wallRunCanEnterLastLogged = canEnter
				local speed = debugContext.horizontalVelocity.Magnitude
				if wallRunQuery then
					local tangent = TraversalMath.WallRunTangent(
						wallRunQuery.normal,
						debugContext.horizontalVelocity
					)
					local dot = if debugContext.moveIntent.direction.Magnitude > 0
						then debugContext.moveIntent.direction.Unit:Dot(tangent)
						else 0
					print(
						string.format(
							"[WallRunCanEnter] %s speed=%.1f (need>=%.1f) dot=%.2f (need>=%.2f) tangent=%s",
							tostring(canEnter),
							speed,
							debugContext.constants.WallRunMinEntrySpeed,
							dot,
							debugContext.constants.WallRunEntryDotThreshold,
							tostring(tangent)
						)
					)
				else
					print(
						string.format(
							"[WallRunCanEnter] %s (no wall) speed=%.1f",
							tostring(canEnter),
							speed
						)
					)
				end
			end
		end

		States[fsm.current].Update(dt, buildContext())

		local claimName = NETWORK_CLAIM_NAMES[fsm.current]
		if claimName and os.clock() - lastClaimResyncAt >= CLAIM_RESYNC_INTERVAL_SECONDS then
			fireClaim(claimName)
		end

		-- Periodic resync while Ctrl is held (same cadence, same self-healing
		-- reasoning as Run/Sprint's own resync above) -- independent of
		-- `fsm.current` on purpose, since the crouch flag matters even while
		-- Airborne (see the mid-air comment above).
		if
			input:IsCrouchHeld()
			and os.clock() - lastCrouchResyncAt >= CLAIM_RESYNC_INTERVAL_SECONDS
		then
			Network.RequestMovementTransition.Fire("CrouchDown")
			lastCrouchResyncAt = os.clock()
		end

		-- F4 debug overlay (docs/MOVEMENT.md) -- published every Heartbeat
		-- regardless of whether the overlay is even open, same as how the FSM's own
		-- context is rebuilt unconditionally; cheap enough (a few field reads, no
		-- allocation-heavy work) not to bother gating on overlay visibility.
		local velocity = rootPart.AssemblyLinearVelocity
		local rotVelocity = rootPart.AssemblyAngularVelocity
		DebugSnapshot.Set({
			state = DEBUG_STATE_NAMES[fsm.current],
			grounded = characterMover:IsGrounded(),
			runDuration = if fsm.current == MovementStates.Run then RunState.GetDuration() else nil,
			speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
			velocity = velocity,
			rotVelocity = rotVelocity,
			noclip = noclipActive,
		})
	end)
end

function MovementController.Init()
	input = InputController.new()

	local player = Players.LocalPlayer
	local lifeTrove: Trove.Trove? = nil

	local function onCharacterAdded(character: Model)
		if lifeTrove then
			lifeTrove:Destroy()
		end
		lifeTrove = Trove.new()
		setupCharacter(character, lifeTrove)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		if lifeTrove then
			lifeTrove:Destroy()
			lifeTrove = nil
		end
	end)

	if player.Character then
		onCharacterAdded(player.Character)
	end
end

return MovementController
