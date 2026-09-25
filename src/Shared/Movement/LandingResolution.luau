--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

type MovementContext = MovementTypes.MovementContext

local LandingResolution = {}

-- Landing target resolution (resolved 2026-09-13, docs/MovementSystem.md §3;
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
-- Hardened 2026-09-18 (real playtest bug: plain sprint + jump + land,
-- SERVER mirror kept resolving to Walk while the client correctly resumed
-- Sprint, triggering a `SpeedCheck.Enforce` rubber-band every ~0.5s): while
-- unlocked, `context.moveIntent.forward` is `classifyMoveIntent`'s
-- facing-vs-MoveDirection geometric approximation on the SERVER (the client's
-- own `forward` is a raw held-key read with no such lag), and
-- `Humanoid.AutoRotate` only turns facing to CATCH UP to MoveDirection
-- gradually while unlocked -- exactly the several-frame window a landing
-- tends to land in right after a jump's own facing/rotation disturbance. The
-- client never has this problem (raw key state doesn't lag), so the
-- resulting client/server disagreement was one-sided: server wrongly
-- demoting to Walk while the client, correctly, kept moving at Sprint speed.
--
-- `context.cameraLocked` skips the unreliable geometric check in exactly that
-- window, but NARROWLY -- only past `moveIntent.backward`, not "any held
-- input" (found immediately after shipping the first version of this fix:
-- a landing genuinely moving backward/unlocked was resuming Sprint/Run
-- anyway, since a bare `not cameraLocked` bypass admits EVERY direction --
-- and `LocomotionAnimator` has no directional variant for Run/Sprint, only
-- Walk's 8-way blend, so that showed up as a forward-sprint clip playing
-- while visibly moving backward, i.e. "the animations are fighting").
-- `moveIntent.backward` is the SAME lagged geometry as `forward`, but a
-- genuine backward hold still reads as clearly opposite-of-facing even
-- through a moderate lag transient (the ambiguous middle ground the lag
-- produces sits much closer to "neither" than to "clearly backward"), so
-- gating on "not explicitly backward" rather than "explicitly forward"
-- keeps the fix narrow: it only rescues the ambiguous near-perpendicular
-- readings the lag window actually produces, not a real reversal.
--
-- Also called for the rare "landed mid-impulse" case (docs/MovementSystem.md §5, Phase 1), where
-- handing off to Airborne first isn't legal (Airborne.CanEnter requires `not grounded`, which
-- already failed by the time this needs to run) -- and reused again by `HardLandingState.Update`
-- (and its own server mirror) to resolve where to go once the lock's own duration elapses -- same
-- "what should I actually be doing right now" question, just asked a beat later.
--
-- Fall height (docs/MovementSystem.md §4.4 rework) is checked FIRST, ahead of
-- crouch/input -- a landing big enough to force `HardLanding` overrides
-- whatever the player was doing or holding on the way down; it isn't just
-- another grounded-state candidate to weigh against Walk/Crouch. Once
-- `HardLanding`'s own lock elapses, `context.fallHeight` has already been
-- cleared (see Movement/init.luau's `peakHeight` bookkeeping), so this same
-- function re-run from there falls straight through to the normal branches
-- below -- no separate "already handled" flag needed.
function LandingResolution.Resolve(context: MovementContext): MovementStates.MovementState
	if
		context.fallHeight
		and context.fallHeight >= context.constants.HardLandingHeightThreshold
	then
		return MovementStates.HardLanding
	end
	local hasInput = StateRules.HasMoveInput(context)
	if context.crouchHeld then
		return if hasInput then MovementStates.CrouchWalk else MovementStates.CrouchIdle
	elseif hasInput then
		local reallyForward = context.moveIntent.forward
			or (not context.cameraLocked and not context.moveIntent.backward)
		if reallyForward and context.preAirborneLocomotion then
			return context.preAirborneLocomotion :: MovementStates.MovementState
		end
		return MovementStates.Walk
	end
	return MovementStates.Idle
end

-- Every state `Resolve` can return, and every airborne-family state whose own
-- landing branch calls it (both sides). A caller missing an edge to any target
-- is stuck in place the moment that target resolves (audit M-005: WallRun had
-- no HardLanding edge), so the invariant is checked once at require time.
local RESOLVE_TARGETS = {
	MovementStates.Idle,
	MovementStates.Walk,
	MovementStates.Run,
	MovementStates.Sprint,
	MovementStates.CrouchIdle,
	MovementStates.CrouchWalk,
	MovementStates.HardLanding,
}

local LANDING_CALLERS = {
	MovementStates.Airborne,
	MovementStates.DoubleJump,
	MovementStates.WallRun,
	MovementStates.WallCling,
	MovementStates.WallBoost,
}

for _, caller in ipairs(LANDING_CALLERS) do
	local edges = StateRules.Transitions[caller]
	for _, target in ipairs(RESOLVE_TARGETS) do
		assert(
			table.find(edges, target) ~= nil,
			`StateRules.Transitions[{tostring(caller)}] is missing landing target {tostring(target)}`
		)
	end
end

return LandingResolution
