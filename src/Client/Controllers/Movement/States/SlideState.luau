--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local SpatialQueriesModule = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
type GroundQueryResult = SpatialQueriesModule.GroundQueryResult

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local SlideState = {}

SlideState.CanEnter = StateRules.CanEnter[MovementStates.Slide]

-- Only the horizontal axes are ever overridden (docs/MovementSystem.md §6) --
-- vertical stays entirely governed by gravity/the Humanoid's own ground
-- adherence, same "disjoint axes" pattern DoubleJump's vertical-only force
-- already established, just the complementary pair.
local HORIZONTAL_ONLY_FORCE = Vector3.new(math.huge, 0, math.huge)

-- Module-scope, not per-context (same pattern as RunState's `enteredAt`): one
-- local-player FSM, so this safely tracks Slide's own continuously-decaying
-- speed/direction across ticks. Exposed via GetCurrentSpeed/GetCurrentDirection
-- so SlideJumpState can read them through `context.slideSpeed`/
-- `context.slideDirection` (ClientMovementContext, `Movement/init.luau` builds
-- them in) rather than requiring this module directly -- states communicate
-- through context, never sibling requires, same as RunState.GetDuration() ->
-- context.runDuration.
local currentSpeed: number? = nil
-- Seeded from real velocity at Entry (residual momentum inherited correctly,
-- same reasoning as `currentSpeed` below), then STEERED every tick after that
-- (docs/MovementSystem.md §4.2, playtest feedback 2026-09-15 -- supersedes this
-- state's earlier "committed action, direction locked at entry" design) --
-- `Update` re-derives it from `CharacterMover:GetFacingDirection()` each
-- frame, so the slide continuously curves toward wherever you're currently
-- looking (Shift Lock/first-person) or facing (Humanoid's own AutoRotate
-- toward held movement input, when unlocked) -- speed/decay are entirely
-- unaffected, only the direction the decaying speed gets applied along.
local currentDirection: Vector3? = nil
local cachedGroundQuery: GroundQueryResult? = nil
local raycastAccumulator = 0

-- Start-of-life reset (audit M-022), called by Movement/init.luau.
function SlideState.Reset()
	currentSpeed = nil
	currentDirection = nil
	cachedGroundQuery = nil
	raycastAccumulator = 0
end

-- Inherits whatever velocity the character actually had the instant Slide was
-- entered (docs/MovementSystem.md §4.2) -- real velocity via
-- CharacterMover:GetHorizontalVelocity(), not the nominal RunSpeed/SprintSpeed
-- constant for whichever state Slide came from, so residual-momentum
-- transients (e.g. sliding right out of a landing) are inherited correctly
-- rather than guessed at. Scaled by `SlideEntrySpeedMultiplier`
-- (docs/MovementSystem.md §4.2, playtest feedback 2026-09-15) -- decay rate alone
-- doesn't determine how far a slide carries you, entry speed matters just as
-- much, and the raw inherited speed (capped by RunSpeed/SprintSpeed) wasn't
-- enough distance for `SlideDecayRate`'s already-confirmed-correct feel. This
-- still scales proportionally with however fast you were actually moving,
-- rather than a flat added number, so Sprint-entry slides stay faster than
-- Run-entry ones.
--
-- Drives a real `LinearVelocity` override (docs/MovementSystem.md §6/§4) instead of
-- `Humanoid.WalkSpeed` -- WalkSpeed is silenced to 0 for the
-- duration of the slide so the Humanoid's own ground-movement controller
-- (which also drives horizontal velocity toward `MoveDirection * WalkSpeed`)
-- doesn't fight the LinearVelocity constraint over the same two axes; every
-- neighboring state Slide can hand off to (CrouchIdle/CrouchWalk) sets its
-- own WalkSpeed on Enter, so this never leaves WalkSpeed stuck at 0 for more
-- than the one frame Slide itself is active.
function SlideState.Enter(context: ClientMovementContext)
	local velocity = context.characterMover:GetHorizontalVelocity()
	-- Clamped to the same ceiling SlideJump and the server's Slide cap use
	-- (SprintSpeed * SlideEntrySpeedMultiplier): residual momentum above
	-- SprintSpeed (a landing, a slope) must not boost the slide past the cap.
	currentSpeed = math.min(velocity.Magnitude, context.constants.SprintSpeed)
		* context.constants.SlideEntrySpeedMultiplier
	currentDirection = if velocity.Magnitude > 0 then velocity.Unit else Vector3.zero
	raycastAccumulator = 0
	cachedGroundQuery = context.characterMover:QueryGround()

	context.characterMover:SetSpeed(0)
	context.characterMover:SetVelocityOverride(
		(currentDirection :: Vector3) * (currentSpeed :: number),
		HORIZONTAL_ONLY_FORCE
	)
end

-- Speed decays via LINEAR friction (docs/MovementSystem.md §4.2,
-- `MovementConstants.SlideDecayRate` -- see that file for why linear over
-- exponential), shaped every tick using Heartbeat's own `dt` -- already a
-- proper delta-time float (never `tick()`-based), the same `os.clock()`-class
-- timing every other duration in this codebase uses, just handed in rather
-- than computed from a stored timestamp here (there's no discrete "entered
-- at" instant to time FROM the way Run's dwell timer has -- Slide's speed
-- itself IS the state being integrated every frame).
--
-- Jump is checked FIRST, before this tick's decay/grounded logic -- SlideJump
-- needs "the speed Slide had a moment ago," which `currentSpeed` still holds
-- at this point in the function, not yet touched by this frame's decay.
--
-- Ground-normal raycast is throttled via a `dt`-accumulator
-- (`SlideGroundRaycastThrottleSeconds`, ARCHITECTURE.md §6) rather than run
-- raw every tick -- the cached result from the last fire is reused on every
-- tick in between, same "expensive read, cheap reuse" shape as any other
-- throttled sensor in this codebase.
--
-- Slope amplification (docs/MovementSystem.md §4 mechanic 3a/3b/3c) is an
-- ADDITIVE top-up applied only to the velocity actually output this tick --
-- it never feeds back into `currentSpeed` itself, so the existing closed-form
-- "(entrySpeed - CrouchSpeed) / SlideDecayRate" duration stays true
-- regardless of terrain; a downhill slide simply moves faster for the same
-- fixed duration, rather than lasting longer.
function SlideState.Update(dt: number, context: ClientMovementContext)
	if context.characterMover:IsJumping() then
		context.fsm:RequestTransition(MovementStates.SlideJump, context)
		return
	end

	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	raycastAccumulator += dt
	if raycastAccumulator >= context.constants.SlideGroundRaycastThrottleSeconds then
		raycastAccumulator = 0
		cachedGroundQuery = context.characterMover:QueryGround()
	end

	-- Steering (docs/MovementSystem.md §4.2, playtest feedback 2026-09-15): re-reads
	-- the rootPart's current facing EVERY tick, not just once at Entry --
	-- `GetFacingDirection` is a cheap CFrame read (no raycast, no throttling
	-- needed), and `FacingController`/`Humanoid.AutoRotate` are already
	-- keeping that facing pointed at the camera look (locked) or held move
	-- input (unlocked) on their own, so this just follows whichever of those
	-- is already live. Guarded on magnitude so looking straight up/down (a
	-- flattened LookVector near zero) can't zero out the slide's direction
	-- for a frame -- falls back to holding the last real direction instead.
	local facing = context.characterMover:GetFacingDirection()
	if facing.Magnitude > 0 then
		currentDirection = facing.Unit
	end

	local speed = math.max(
		context.constants.CrouchSpeed,
		(currentSpeed or context.constants.CrouchSpeed) - context.constants.SlideDecayRate * dt
	)
	currentSpeed = speed

	local amplification = 0
	if cachedGroundQuery and currentDirection then
		amplification = TraversalMath.SlideSlopeAmplification(
			cachedGroundQuery.normal,
			currentDirection,
			math.rad(context.constants.SlideSlopeAngleThresholdDegrees),
			math.rad(context.constants.SlideMaxWalkableSlopeDegrees),
			context.constants.SlideSlopeAmplificationCap
		)
	end

	context.characterMover:SetVelocityOverride(
		(currentDirection or Vector3.zero) * (speed + amplification),
		HORIZONTAL_ONLY_FORCE
	)

	-- Automatic hand-off once decay crosses the crouch-speed threshold
	-- (docs/MovementSystem.md §4.2) -- unconditional on `crouchHeld`: if Ctrl was
	-- already released before decay finished, the resulting CrouchWalk/
	-- CrouchIdle's OWN Update immediately notices on the very next tick and
	-- releases into Walk/Idle -- no special-casing needed here for that.
	-- Gated on the BASE decayed `speed`, not the slope-amplified output, so a
	-- steep downhill slide can't extend its own duration past the fixed
	-- closed-form decay window.
	if speed <= context.constants.CrouchSpeed then
		context.fsm:RequestTransition(
			if StateRules.HasMoveInput(context)
				then MovementStates.CrouchWalk
				else MovementStates.CrouchIdle,
			context
		)
	end
end

function SlideState.Exit(context: ClientMovementContext)
	context.characterMover:ClearVelocityOverride()
	currentSpeed = nil
	currentDirection = nil
	cachedGroundQuery = nil
	raycastAccumulator = 0
end

function SlideState.GetCurrentSpeed(): number?
	return currentSpeed
end

function SlideState.GetCurrentDirection(): Vector3?
	return currentDirection
end

return SlideState
