--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- SlideJump's own duration is intentionally one frame -- it's not a parallel
-- air-control implementation (docs/MovementSystem.md §4.2). Enter applies the boost
-- and immediately hands off to Airborne in the SAME synchronous call (the
-- `RequestTransition` below fires `fsm.changed` reentrantly, which LemonSignal
-- runs via `task.spawn` -- effectively synchronous as long as nothing yields,
-- which nothing here does) -- so `Update`/`Exit` never actually run for a
-- real frame; kept only for contract symmetry with every other state module.
-- Airborne itself (gravity curve, partial air control, double jump) is
-- entirely unmodified by this -- it applies the same regardless of how the
-- player got airborne.
local SlideJumpState = {}

SlideJumpState.CanEnter = StateRules.CanEnter[MovementStates.SlideJump]

-- The boost is clamped to `SprintSpeed * SlideEntrySpeedMultiplier`
-- (docs/MovementSystem.md §4.2) -- the SAME ceiling Slide itself now uses
-- (`SlideState.Enter`, docs/MovementSystem.md §4 + the 2026-09-15
-- entry-speed tuning pass), NOT a bare `SprintSpeed` -- clamping to the old,
-- unboosted ceiling here would silently undo the entry-speed boost the
-- instant you jumped out of a fast slide. Rather than left unbounded and
-- relying on the landing-momentum grace mechanism to cover the overshoot;
-- that mechanism only grants grace when the cap DECREASED at the last
-- transition, which doesn't help here since Slide's own cap is already that
-- same ceiling.
--
-- Reads Slide's real velocity DIRECTION (`context.slideDirection`, set by
-- `SlideState.GetCurrentDirection`) rather than the Humanoid's current
-- `MoveDirection` (docs/MovementSystem.md §4) -- now that Slide itself
-- drives a real `LinearVelocity` instead of a WalkSpeed magnitude, "the speed
-- Slide had a moment ago" has a real direction attached, not just a number.
-- Applied as a single direct impulse (`SetHorizontalVelocity`, NOT
-- `SetVelocityOverride`) since SlideJump's own Enter transitions synchronously
-- into Airborne in the same call (see this state's own doc comment above) --
-- Exit never runs a real frame to clear a constraint-backed override, so a
-- direct one-shot write is the only safe way to apply this boost without
-- permanently locking horizontal velocity for the rest of the fall.
-- `SetSpeed` is ALSO set to the boosted value (mirroring the old WalkSpeed-
-- driven design) purely so Airborne's own partial air control has the
-- boosted magnitude as its target, same "whatever tier was active at takeoff
-- carries into the jump" carry-through every other jump-off already gets.
function SlideJumpState.Enter(context: ClientMovementContext)
	local entrySpeed = context.slideSpeed or context.constants.CrouchSpeed
	local ceiling = context.constants.SprintSpeed * context.constants.SlideEntrySpeedMultiplier
	local boosted = math.min(entrySpeed + context.constants.SlideJumpBoostAmount, ceiling)
	local direction = context.slideDirection or Vector3.zero

	context.characterMover:SetHorizontalVelocity(direction * boosted)
	-- The launch height is designed, not whatever the slide happened to leave
	-- in the Humanoid's jump: the server's vertical ceiling allows exactly
	-- this (see SlideJumpUpwardSpeed).
	context.characterMover:SetVerticalVelocity(MovementConstants.SlideJumpUpwardSpeed)
	context.characterMover:SetSpeed(boosted)
	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

function SlideJumpState.Update(_dt: number, _context: ClientMovementContext) end

function SlideJumpState.Exit(_context: ClientMovementContext) end

return SlideJumpState
