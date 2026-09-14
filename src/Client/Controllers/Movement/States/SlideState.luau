--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local SlideState = {}

SlideState.CanEnter = StateRules.CanEnter[MovementStates.Slide]

-- Module-scope, not per-context (same pattern as RunState's `enteredAt`): one
-- local-player FSM, so this safely tracks Slide's own continuously-decaying
-- speed across ticks. Exposed via GetCurrentSpeed so SlideJumpState can read
-- it through `context.slideSpeed` (ClientMovementContext, `Movement/init.luau`
-- builds it in) rather than requiring this module directly -- states
-- communicate through context, never sibling requires, same as
-- RunState.GetDuration() -> context.runDuration.
local currentSpeed: number? = nil

-- Inherits whatever speed the character actually had the instant Slide was
-- entered (docs/MOVEMENT.md §9) -- real velocity via CharacterMover:GetSpeed(),
-- not the nominal RunSpeed/SprintSpeed constant for whichever state Slide came
-- from, so residual-momentum transients (e.g. sliding right out of a landing)
-- are inherited correctly rather than guessed at.
function SlideState.Enter(context: ClientMovementContext)
	currentSpeed = context.characterMover:GetSpeed()
	context.characterMover:SetSpeed(currentSpeed)
end

-- Speed decays via LINEAR friction (docs/MOVEMENT.md §9,
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
function SlideState.Update(dt: number, context: ClientMovementContext)
	if context.characterMover:IsJumping() then
		context.fsm:RequestTransition(MovementStates.SlideJump, context)
		return
	end

	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local speed = math.max(
		context.constants.CrouchSpeed,
		(currentSpeed or context.constants.CrouchSpeed) - context.constants.SlideDecayRate * dt
	)
	currentSpeed = speed
	context.characterMover:SetSpeed(speed)

	-- Automatic hand-off once decay crosses the crouch-speed threshold
	-- (docs/MOVEMENT.md §9) -- unconditional on `crouchHeld`: if Ctrl was
	-- already released before decay finished, the resulting CrouchWalk/
	-- CrouchIdle's OWN Update immediately notices on the very next tick and
	-- releases into Walk/Idle -- no special-casing needed here for that.
	if speed <= context.constants.CrouchSpeed then
		context.fsm:RequestTransition(
			if StateRules.HasMoveInput(context) then MovementStates.CrouchWalk else MovementStates.CrouchIdle,
			context
		)
	end
end

function SlideState.Exit(_context: ClientMovementContext)
	currentSpeed = nil
end

function SlideState.GetCurrentSpeed(): number?
	return currentSpeed
end

return SlideState
