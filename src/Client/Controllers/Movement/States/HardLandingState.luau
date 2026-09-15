--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Real, timed movement lock (docs/MOVEMENT.md §10 rework) -- entered instead
-- of the normal landing target when `AirborneState.ResolveLandingTarget`
-- decides the fall was big enough (`context.fallHeight >=
-- constants.HardLandingHeightThreshold`). Unlike SlideJump (a one-frame
-- hand-off with no real Update), this is a genuine state that persists for
-- its own real duration -- `LocomotionAnimator`'s per-state resolution picks
-- "LandHard" for as long as it's `fsm.current`, no one-shot animation-hold
-- hack needed.
--
-- Mirrored server-side (`MovementValidationService.mirrorPassiveTransitions`'s
-- own HardLanding branch, `maxSpeedForState`'s HardLanding -> 0 cap) so the
-- lock is authoritative, not just a client-side courtesy -- same "never trust
-- the client" standard as every other movement state here
-- (docs/ARCHITECTURE.md §3).
local HardLandingState = {}

HardLandingState.CanEnter = StateRules.CanEnter[MovementStates.HardLanding]

-- Module-scope, not per-context -- same single-local-player-FSM pattern as
-- RunState's dwell timer / SlideState's currentSpeed.
local lockedUntil: number? = nil

-- WalkSpeed pinned to 0 (not a WalkSpeed=0-while-`grounded`-only trick --
-- SetJumpBlocked also stops a locked player from cancelling the lock into a
-- fresh jump, same mechanism CrouchIdle already uses for "can't jump while
-- crouched"). Facing/camera control is untouched -- only horizontal
-- locomotion and jumping are locked, same scope docs/MOVEMENT.md §9's own
-- crouch jump-block already established.
function HardLandingState.Enter(context: ClientMovementContext)
	context.characterMover:SetSpeed(0)
	context.characterMover:SetJumpBlocked(true)
	lockedUntil = os.clock() + context.constants.HardLandingDurationSeconds
end

-- Losing the ground mid-lock (e.g. the floor gives way) is involuntary --
-- unconditional, same as every other grounded state's own `not grounded ->
-- Airborne` check, and takes priority over the lock timer since there's
-- nothing left to lock the player TO. Otherwise holds until `lockedUntil`
-- elapses, then re-runs the SAME landing resolution Airborne itself used --
-- `context.fallHeight` has already been cleared by this point (Movement/
-- init.luau's `peakHeight` bookkeeping, cleared the instant HardLanding was
-- first entered), so this always resolves to an ordinary grounded target,
-- never back into HardLanding again.
function HardLandingState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end
	if lockedUntil and os.clock() < lockedUntil then
		return
	end
	context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
end

function HardLandingState.Exit(context: ClientMovementContext)
	context.characterMover:SetJumpBlocked(false)
	lockedUntil = nil
end

return HardLandingState
