--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local AirborneState = {}

AirborneState.CanEnter = StateRules.CanEnter[MovementStates.Airborne]

-- Landing target resolution (resolved 2026-09-13, docs/MOVEMENT.md §2;
-- extended 2026-09-14 §9 with the crouch branch; extended again with the
-- landing-resume fix) -- resolves straight to the real grounded target based
-- on currently held input, never through an intermediate Idle frame.
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
-- Extracted into its own function (TRAVERSAL-ROADMAP.md §4, Phase 1) so
-- DoubleJumpState can resolve the SAME landing decision for the rare "landed
-- mid-impulse" case, where handing off to Airborne first isn't legal
-- (Airborne.CanEnter requires `not grounded`, which already failed by the
-- time this needs to run) -- single source of truth, not a second copy of
-- the same crouch/hasInput/resume/HardLanding branching. Also reused by
-- `HardLandingState.Update` (and its own server mirror) to resolve where to
-- go once the lock's own duration elapses -- same "what should I actually be
-- doing right now" question, just asked a beat later.
--
-- Fall height (docs/MOVEMENT.md §10 rework) is checked FIRST, ahead of
-- crouch/input -- a landing big enough to force `HardLanding` overrides
-- whatever the player was doing or holding on the way down; it isn't just
-- another grounded-state candidate to weigh against Walk/Crouch. Once
-- `HardLanding`'s own lock elapses, `context.fallHeight` has already been
-- cleared (see Movement/init.luau's `peakHeight` bookkeeping), so this same
-- function re-run from there falls straight through to the normal branches
-- below -- no separate "already handled" flag needed.
function AirborneState.ResolveLandingTarget(context: ClientMovementContext): MovementStates.MovementState
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

function AirborneState.Enter(_context: ClientMovementContext) end

-- The decision lives in Update, not Exit: by the time Exit runs for the state
-- being left, RequestTransition has already committed to the next state
-- (StateMachine.luau fires `changed` after updating `current`), so Exit can
-- only ever be teardown, never the thing choosing where to land.
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		return
	end
	context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
