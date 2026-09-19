--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Simplest of the five traversal moves (TRAVERSAL-ROADMAP.md §8 Phase 1): a
-- decaying vertical-only LinearVelocity impulse, gated by "already airborne +
-- air-jump not yet used this life." No raycasting, no continuous input --
-- `TraversalMath.DoubleJumpVerticalVelocity` is a pure function of elapsed
-- time alone, which is also why this needs no `TraversalInput` stream:
-- there's nothing for the player to steer mid-impulse.
local DoubleJumpState = {}

DoubleJumpState.CanEnter = StateRules.CanEnter[MovementStates.DoubleJump]

-- Module-scope, not per-context -- same pattern as RunState's dwell timer and
-- SlideState's currentSpeed: one local-player FSM, so this safely tracks the
-- single in-flight impulse's own start time across ticks.
local enteredAt: number? = nil

-- `maxForce` only allows the Y axis (TRAVERSAL-ROADMAP.md §2/§11) -- X/Z stay
-- entirely governed by the Humanoid's normal WalkSpeed-driven movement, so
-- this never fights horizontal air control the way forcing the full vector
-- would.
local VERTICAL_ONLY_FORCE = Vector3.new(0, math.huge, 0)

function DoubleJumpState.Enter(context: ClientMovementContext)
	enteredAt = os.clock()
	local velocity = TraversalMath.DoubleJumpVerticalVelocity(
		0,
		context.constants.DoubleJumpForce,
		context.constants.DoubleJumpDecayDurationSeconds
	)
	context.characterMover:SetVelocityOverride(Vector3.new(0, velocity, 0), VERTICAL_ONLY_FORCE)
end

-- Hands back to Airborne once the decay curve finishes (TRAVERSAL-ROADMAP.md
-- §4's correction: every traversal move that can end mid-air must route back
-- through Airborne, or it silently bypasses landing resolution/the Fall
-- animation). Landing mid-impulse is handled as its OWN branch, not folded
-- into the same "-> Airborne" call: `Airborne.CanEnter` requires `not
-- grounded`, which has already failed by the instant `context.grounded`
-- reads true here, so that transition would simply be rejected and leave the
-- FSM stuck in DoubleJump. Resolving straight to the real grounded target
-- (`AirborneState.ResolveLandingTarget`, the same decision Airborne's own
-- Update makes) is what SlideJump's Enter and Airborne's landing edge already
-- rely on elsewhere -- a single-tick decision, not a DoubleJump-then-Airborne-
-- then-grounded cascade.
function DoubleJumpState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	local elapsed = os.clock() - (enteredAt :: number)
	local decayDuration = context.constants.DoubleJumpDecayDurationSeconds

	if elapsed >= decayDuration then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local velocity = TraversalMath.DoubleJumpVerticalVelocity(
		elapsed,
		context.constants.DoubleJumpForce,
		decayDuration
	)
	context.characterMover:SetVelocityOverride(Vector3.new(0, velocity, 0), VERTICAL_ONLY_FORCE)
end

function DoubleJumpState.Exit(context: ClientMovementContext)
	context.characterMover:ClearVelocityOverride()
	enteredAt = nil
end

return DoubleJumpState
