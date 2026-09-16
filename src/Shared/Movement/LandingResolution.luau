--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

type MovementContext = MovementTypes.MovementContext

local LandingResolution = {}

-- Landing target resolution (resolved 2026-09-13, docs/MOVEMENT.md §2;
-- extended 2026-09-14 §9 with the crouch branch; extended again with the
-- landing-resume fix). Unified here during the 2026-09-15 cleanup pass --
-- previously hand-duplicated verbatim as `AirborneState.ResolveLandingTarget`
-- (client) and a module-local `resolveLandingTarget` (MovementValidationService,
-- server); both only ever touched plain `MovementContext` fields (fallHeight,
-- constants, crouchHeld, moveIntent.forward, preAirborneLocomotion), so this is
-- the same "one pure function, called identically by both sides" treatment
-- `TraversalMath.luau`/`SpatialQueries.luau` already established, not a new
-- pattern for this codebase. Resolves straight to the real grounded target
-- based on currently held input, never through an intermediate Idle frame.
--
-- Resumes Run/Sprint on landing (landing-resume fix) rather than always
-- demoting to Walk: `context.preAirborneLocomotion` is whichever of the two
-- this life was actually in the instant it left the ground (tracked in
-- Movement/init.luau, mirrored server-side), and forward still being held on
-- touchdown is the "didn't let go of W" signal that distinguishes a genuine
-- resume from a player who bailed out of their sprint mid-air -- backpedaling
-- or pure-strafing on landing still falls through to Walk exactly like
-- before. `StateRules.CanEnter[Sprint]` has its own matching carve-out for
-- this same field, since a resumed Sprint has no `runDuration` to re-check
-- (fsm.current is still Airborne here, not Run).
--
-- Also called for the rare "landed mid-impulse" case (TRAVERSAL-ROADMAP.md
-- §4, Phase 1), where handing off to Airborne first isn't legal
-- (Airborne.CanEnter requires `not grounded`, which already failed by the
-- time this needs to run) -- and reused again by `HardLandingState.Update`
-- (and its own server mirror) to resolve where to go once the lock's own
-- duration elapses -- same "what should I actually be doing right now"
-- question, just asked a beat later.
--
-- Fall height (docs/MOVEMENT.md §10 rework) is checked FIRST, ahead of
-- crouch/input -- a landing big enough to force `HardLanding` overrides
-- whatever the player was doing or holding on the way down; it isn't just
-- another grounded-state candidate to weigh against Walk/Crouch. Once
-- `HardLanding`'s own lock elapses, `context.fallHeight` has already been
-- cleared (see Movement/init.luau's `peakHeight` bookkeeping), so this same
-- function re-run from there falls straight through to the normal branches
-- below -- no separate "already handled" flag needed.
function LandingResolution.Resolve(context: MovementContext): MovementStates.MovementState
	if context.fallHeight and context.fallHeight >= context.constants.HardLandingHeightThreshold then
		return MovementStates.HardLanding
	end
	local hasInput = StateRules.HasMoveInput(context)
	if context.crouchHeld then
		return if hasInput then MovementStates.CrouchWalk else MovementStates.CrouchIdle
	elseif hasInput then
		if context.moveIntent.forward and context.preAirborneLocomotion then
			return context.preAirborneLocomotion :: MovementStates.MovementState
		end
		return MovementStates.Walk
	end
	return MovementStates.Idle
end

return LandingResolution
