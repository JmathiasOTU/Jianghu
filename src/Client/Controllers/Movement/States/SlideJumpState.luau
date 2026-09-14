--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- SlideJump's own duration is intentionally one frame -- it's not a parallel
-- air-control implementation (docs/MOVEMENT.md §9). Enter applies the boost
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

-- The boost is clamped to the SprintSpeed ceiling (docs/MOVEMENT.md §9) --
-- the SAME ceiling Slide/Airborne already share -- rather than left
-- unbounded and relying on the landing-momentum grace mechanism to cover the
-- overshoot; that mechanism only grants grace when the cap DECREASED at the
-- last transition, which doesn't help here since Slide's own cap is already
-- that same ceiling. Setting WalkSpeed to the boosted value here (not a
-- direct AssemblyLinearVelocity impulse) reuses the same "whatever tier was
-- active at takeoff carries into the jump" mechanic Airborne already relies
-- on for every other state -- no new physics API, no new server trust
-- surface: the server's own flat SprintSpeed ceiling for Slide/SlideJump/
-- Airborne already covers this boost the same way it covers everything else.
function SlideJumpState.Enter(context: ClientMovementContext)
	local entrySpeed = context.slideSpeed or context.constants.CrouchSpeed
	local boosted = math.min(entrySpeed + context.constants.SlideJumpBoostAmount, context.constants.SprintSpeed)
	context.characterMover:SetSpeed(boosted)
	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

function SlideJumpState.Update(_dt: number, _context: ClientMovementContext) end

function SlideJumpState.Exit(_context: ClientMovementContext) end

return SlideJumpState
