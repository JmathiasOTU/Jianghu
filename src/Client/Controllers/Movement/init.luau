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
local SpatialQueriesModule = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
type WallQueryResult = SpatialQueriesModule.WallQueryResult

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
local WallClimbState = require(script.States.WallClimbState)

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
	[MovementStates.WallClimb] = WallClimbState,
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

local input: InputController.InputController

local function setupCharacter(character: Model, lifeTrove: Trove.Trove)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local characterMover = lifeTrove:Add(CharacterMover.new(humanoid, TuningSnapshot.Get().JumpPower))
	local noclip = lifeTrove:Add(NoclipController.new(humanoid, rootPart, input))
	local fsm = lifeTrove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)

	-- Presentation: purely cosmetic, never touched by states or the FSM (they only
	-- read it) -- docs/MOVEMENT.md §3/§4.
	lifeTrove:Add(FacingController.new(humanoid, rootPart))
	lifeTrove:Add(LocomotionAnimator.new(humanoid, rootPart, fsm, input, characterMover))

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
			DoubleJumpForce = value.doubleJumpForce,
			DoubleJumpDecayDurationSeconds = value.doubleJumpDecayDurationSeconds,
			SlideSlopeAngleThresholdDegrees = value.slideSlopeAngleThresholdDegrees,
			SlideMaxWalkableSlopeDegrees = value.slideMaxWalkableSlopeDegrees,
			SlideSlopeAmplificationCap = value.slideSlopeAmplificationCap,
			SlideGroundRaycastThrottleSeconds = value.slideGroundRaycastThrottleSeconds,
			WallDetectMaxUpDot = value.wallDetectMaxUpDot,
			WallDetectRaycastThrottleSeconds = value.wallDetectRaycastThrottleSeconds,
			WallRunSpeed = value.wallRunSpeed,
			WallRunMaxDurationSeconds = value.wallRunMaxDurationSeconds,
			WallClimbSpeed = value.wallClimbSpeed,
			WallClimbSnapDistance = value.wallClimbSnapDistance,
			WallClimbJumpForce = value.wallClimbJumpForce,
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

	-- WallRun/WallClimb's own wall probe (TRAVERSAL-ROADMAP.md §8 Phase 4) --
	-- their CanEnter predicates (Shared/Movement/StateRules.luau) need "is
	-- there a wall here right now" as part of the shared MovementContext, so
	-- (unlike Slide's ground-normal cache, which is state-module-local since
	-- Slide's own CanEnter never checks it) this has to be refreshed once per
	-- Heartbeat, ahead of `Update`, and threaded through `buildContext` below.
	-- Throttled via a `dt`-accumulator (ARCHITECTURE.md §6, same idiom
	-- SlideState's own ground raycast already uses) and only probed at all
	-- while airborne -- a grounded player never needs this, same "no blanket
	-- per-tick cost" reasoning that raycast throttle already exists for.
	local wallQuery: WallQueryResult? = nil
	local wallQueryAccumulator = 0

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
			wallQuery = wallQuery,
			-- Still an open design decision (TRAVERSAL-ROADMAP.md §0/§3) --
			-- "always available" until a real Qinggong/stamina resource
			-- exists, same placeholder both sides use.
			qinggong = math.huge,
			constants = TuningSnapshot.Get(),
			characterMover = characterMover,
			fsm = fsm,
			slideSpeed = SlideState.GetCurrentSpeed(),
			slideDirection = SlideState.GetCurrentDirection(),
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
		States[next].Enter(context)

		-- F4 debug overlay state history (docs/MOVEMENT.md §8): populated off
		-- this existing `fsm.changed` connection, not a new one.
		DebugSnapshot.RecordTransition(DEBUG_STATE_NAMES[next])

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
		if next == MovementStates.DoubleJump then
			doubleJumpUsed = true
			Network.ClaimTraversalMove.Fire("DoubleJump")
		elseif next == MovementStates.WallRun then
			-- WallRun/WallClimb (TRAVERSAL-ROADMAP.md §6/§8 Phase 4): claimed
			-- the same way DoubleJump is -- fired once on entry, never a
			-- continuous stream (no TraversalInput-style event exists in this
			-- codebase; see MovementValidationService's own per-Heartbeat
			-- geometry recheck for how the server keeps validating the move
			-- afterward without one).
			Network.ClaimTraversalMove.Fire("WallRun")
		elseif next == MovementStates.WallClimb then
			Network.ClaimTraversalMove.Fire("WallClimb")
		elseif GROUNDED_STATES[next] then
			doubleJumpUsed = false
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
		-- there is SlideJump); excluded when `previous == DoubleJump` so the
		-- Airborne <-> DoubleJump hop doesn't reset the peak mid-excursion.
		-- Cleared the instant a landing actually resolves, same edge as
		-- `preAirborneLocomotion` just above.
		if next == MovementStates.Airborne then
			if previous ~= MovementStates.DoubleJump then
				peakHeight = rootPart.Position.Y
			end
		elseif GROUNDED_STATES[next] then
			peakHeight = nil
		end
	end)

	lifeTrove:Connect(input.RunRequested, function()
		fsm:RequestTransition(MovementStates.Run, buildContext())
	end)

	-- DoubleJump's own entry trigger (TRAVERSAL-ROADMAP.md §4) -- fires on
	-- EVERY jump-action request regardless of grounded state (see
	-- InputController.JumpRequested's own doc comment for why that has to be
	-- the signal); no explicit "currently Airborne" guard needed here, same
	-- reasoning as SlideJump's own CanEnter comment -- topology alone already
	-- makes this a no-op unless DoubleJump is actually reachable from the
	-- current state.
	lifeTrove:Connect(input.JumpRequested, function()
		-- WallClimb's own jump press is a dedicated exit (ClimbJump, mechanic
		-- 5a) that applies a real launch impulse on the way out -- routed
		-- here instead of through RequestTransition's normal CanEnter path,
		-- since a bare state-symbol target has nowhere to carry that impulse.
		-- Every other state falls through to the ordinary DoubleJump attempt,
		-- unconditionally, same as before this branch existed.
		if fsm.current == MovementStates.WallClimb then
			WallClimbState.ClimbJump(buildContext())
			return
		end
		fsm:RequestTransition(MovementStates.DoubleJump, buildContext())
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

		-- Wall probe (TRAVERSAL-ROADMAP.md §8 Phase 4) -- BEFORE `Update`
		-- below, same ordering reasoning as `peakHeight`'s own comment: this
		-- frame's WallRun/WallClimb CanEnter check (inside AirborneState.Update
		-- or the states' own Update) has to see a freshly-refreshed query, not
		-- last frame's. Cleared immediately on grounding rather than left to
		-- decay via the throttle, so a landed player's very next CanEnter
		-- check never sees a stale wall.
		if characterMover:IsGrounded() then
			wallQuery = nil
			wallQueryAccumulator = 0
		else
			wallQueryAccumulator += dt
			if wallQueryAccumulator >= TuningSnapshot.Get().WallDetectRaycastThrottleSeconds then
				wallQueryAccumulator = 0
				wallQuery = characterMover:QueryWall()
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
		if input:IsCrouchHeld() and os.clock() - lastCrouchResyncAt >= CLAIM_RESYNC_INTERVAL_SECONDS then
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
