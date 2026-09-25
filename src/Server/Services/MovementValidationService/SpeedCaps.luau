--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local Sessions = require(script.Parent.Sessions)

type MovementState = MovementStates.MovementState
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- The horizontal speed each mirrored state allows (docs/MovementSystem.md
-- §8.2): per-state caps, launch allowances that outlive their state, and
-- the landing-momentum grace.
local SpeedCaps = {}

-- Absorbs standing-still jitter during HardLanding's WalkSpeed=0 lock without
-- tolerating a real WASD movement attempt.
local HARD_LANDING_RESIDUAL_SPEED_TOLERANCE = 6

-- Sized from a real 2026-09-14 playtest capture (docs/MovementSystem.md §8), not a
-- guess: every landing sample showed the FIRST `SpeedCheck.Enforce` check after
-- an Airborne->Walk transition firing at elapsed ~0.50-0.517s (just the normal
-- check cadence) and never a second correction after it -- the whole residual-
-- momentum transient decays back under the new cap within that first window,
-- it just needs grace that actually covers it. One `SpeedCheckIntervalSeconds`
-- of grace (the original placeholder) was already expired BY the time that
-- first check ran (elapsed >= grace), which is why it measured zero
-- protection. Two intervals comfortably covers the observed ~0.5-0.517s first
-- check with margin, without over-granting a second window nothing in the
-- capture ever showed a need for.
SpeedCaps.LANDING_MOMENTUM_GRACE_SECONDS = 2 * MovementConstants.SpeedCheckIntervalSeconds

-- The fastest a slide or slide jump ever goes before slope amplification:
-- SlideState.Enter and SlideJumpState.Enter both clamp to it client-side.
function SpeedCaps.SlideCeiling(constants: EffectiveMovementConstants): number
	return constants.SprintSpeed * constants.SlideEntrySpeedMultiplier
end

-- Companion to the client's own slope-amplification read (SlideState.Update)
-- -- same `TraversalMath.SlideSlopeAmplification` function, fed the server's
-- own cached ground-normal and the session's replicated
-- `AssemblyLinearVelocity` direction. That velocity is client-written, but it
-- only picks a direction here: the amplification it can unlock is capped at
-- `SlideSlopeAmplificationCap` and needs a real server-probed slope.
local function slideSlopeAmplification(
	session: PlayerSession,
	constants: EffectiveMovementConstants
): number
	local query = session.slideGroundQuery
	if not query then
		return 0
	end

	local velocity = session.rootPart.AssemblyLinearVelocity
	local direction = Vector3.new(velocity.X, 0, velocity.Z)
	if direction.Magnitude == 0 then
		return 0
	end

	return TraversalMath.SlideSlopeAmplification(
		query.normal,
		direction.Unit,
		math.rad(constants.SlideSlopeAngleThresholdDegrees),
		math.rad(constants.SlideMaxWalkableSlopeDegrees),
		constants.SlideSlopeAmplificationCap
	)
end

-- WalkSpeed is the ground-truth cap Roblox's own Humanoid:Move() enforces for a
-- well-behaved client, but WalkSpeed itself is just a replicated property the
-- network-owning client (the player, for their own character) can set directly --
-- a classic speed-hack bypasses the FSM entirely and never calls
-- RequestMovementTransition at all, it just writes a bigger WalkSpeed straight onto
-- the Humanoid. So the cap checked here is keyed off the SERVER's own mirrored FSM
-- state, never `humanoid.WalkSpeed` as reported -- that value can't be trusted at
-- all (docs/ARCHITECTURE.md §3). Airborne has no state of its own that sets speed
-- (`AirborneState.Enter` is a no-op, per `AirborneState.luau`) -- whatever tier was
-- active at takeoff carries into the jump -- so it's capped at the ceiling
-- (SprintSpeed) rather than guessing which tier the player jumped from.
-- Crouch/Slide additions (docs/MovementSystem.md §4.2): CrouchIdle/CrouchWalk cap at
-- CrouchSpeed, same "own dedicated tier" treatment as Walk/Run.
--
-- Slide/SlideJump cap became a FORMULA, not a flat tier (docs/MovementSystem.md §8, Phase 3):
-- `SprintSpeed * SlideEntrySpeedMultiplier` -- the SAME boosted ceiling
-- `SlideState.Enter`/`SlideJumpState.Enter` clamp to client-side (docs/MovementSystem.md §4.2,
-- 2026-09-15 entry-speed tuning pass; before that pass this was a bare `SprintSpeed`, same
-- reasoning as Airborne's existing ceiling) -- PLUS `slopeAmplification`, the same downhill top-up
-- `TraversalMath.SlideSlopeAmplification` grants the client, so a real slope-boosted slide doesn't
-- rubber-band against a cap that only ever assumed flat ground. `slopeAmplification` defaults to 0
-- for every call site that doesn't have a live ground read to pass.
local function maxSpeedForState(
	state: MovementState,
	constants: EffectiveMovementConstants,
	slopeAmplification: number?
): number
	if state == MovementStates.Run then
		return constants.RunSpeed
	elseif state == MovementStates.Slide or state == MovementStates.SlideJump then
		return SpeedCaps.SlideCeiling(constants) + (slopeAmplification or 0)
	elseif
		state == MovementStates.Sprint
		or state == MovementStates.Airborne
		or state == MovementStates.DoubleJump
		or state == MovementStates.WallLeap
	then
		-- DoubleJump/WallLeap only ever apply a launch impulse -- horizontal
		-- speed otherwise carries through from whatever tier was active at
		-- takeoff, same "ceiling, not a guessed tier" reasoning Airborne
		-- already uses. Neither is ever actually the LIVE `session.fsm.current`
		-- for more than the one accepting Heartbeat (WallLeap hands straight
		-- back to Airborne in the same call, docs/MovementSystem.md §8.4) -- this branch only
		-- matters for the `previousCap` grace snapshot right after one of
		-- them; WallLeap's (and SlideJump's) real launch speed comes from
		-- `airborneAllowedSpeed`.
		return constants.SprintSpeed
	elseif state == MovementStates.WallRun then
		-- Live-capped at the mechanic's OWN tuned speed (docs/MovementSystem.md §8.4),
		-- deliberately NOT suspended like DoubleJump/WallLeap's one-shot
		-- impulses -- WallRun is sustained, so exempting the whole hold would
		-- let a modified client fly at any speed for as long as it claims
		-- WallRun. `SpeedCheck.Enforce` stays live throughout, just raised to
		-- this cap instead of Airborne's lower SprintSpeed ceiling.
		return constants.WallRunSpeed
	elseif state == MovementStates.WallCling then
		-- No horizontal drift while clinging (docs/MovementSystem.md §8.2)
		-- -- a fixed, non-tunable literal, not `constants.WallClingSpeedCeiling`
		-- (deliberately excluded from live tuning, docs/ARCHITECTURE.md §9's
		-- "no band-aid validation": any non-zero value needs a specific,
		-- measured, documented cause, not a knob a developer can nudge away a
		-- false flag with).
		return MovementConstants.WallClingSpeedCeiling
	elseif state == MovementStates.WallBoost then
		-- Same "one-shot impulse" shape as DoubleJump/WallLeap above: the
		-- boost's horizontal part (`WallBoostSeparationSpeed`) sits under this
		-- cap, and its vertical part is enforced by the vertical ceiling.
		return constants.SprintSpeed
	elseif state == MovementStates.CrouchIdle or state == MovementStates.CrouchWalk then
		return constants.CrouchSpeed
	elseif state == MovementStates.HardLanding then
		-- Not a literal 0 -- that made maxDistance always exactly 0, flagging
		-- even standing-still jitter every single check.
		return HARD_LANDING_RESIDUAL_SPEED_TOLERANCE
	end
	return constants.WalkSpeed
end

-- Landing-momentum grace (docs/MovementSystem.md §8, added 2026-09-14): distinct from
-- `createSession`'s existing per-transition baseline reset below, which only
-- ever fixed windows that straddled a transition boundary (mixing old- and
-- new-tier motion in one sample). This fixes a DIFFERENT case -- a window
-- entirely AFTER a transition, already in the new state, still measuring real
-- residual momentum: Humanoid's ground controller decelerates toward a lower
-- WalkSpeed target over a real, documented handful of frames rather than
-- snapping instantly, and that tail can genuinely exceed the new tier's cap for
-- a moment (most sharply landing from Sprint/Airborne down into Walk).
--
-- Keyed generically off "the cap decreased at the last transition," never off
-- "coming from Airborne" or "going to Walk" specifically -- `session.previousState`
-- is whatever state was active immediately before, so Stage 2's WallRun/
-- ClimbVault/LedgeGrab/Slide (all of which will exit into Airborne or Walk with
-- their own residual momentum) get this grace for free the moment their own cap
-- is taught to `maxSpeedForState`, with no separate copy of this fix needed.
function SpeedCaps.CapForState(
	session: PlayerSession,
	state: MovementState,
	constants: EffectiveMovementConstants
): number
	local currentCap =
		maxSpeedForState(state, constants, slideSlopeAmplification(session, constants))

	-- A fast launch's own computed ceiling (WallLeap, playtest fix 2026-09-18;
	-- SlideJump) -- takes over from the ordinary Airborne/SprintSpeed cap for
	-- as long as the flight lasts (see the field's own comment on
	-- `PlayerSession`). `math.max`, not an unconditional
	-- override -- never LOWERS the cap below whatever the state would allow.
	local allowance = session.airborneAllowedSpeed
	local expiresAt = session.airborneAllowanceExpiresAt
	if allowance and allowance > currentCap and not (expiresAt and os.clock() >= expiresAt) then
		currentCap = allowance
	end

	-- No WallBoost term (audit M-024): the boost's horizontal part is only
	-- `WallBoostSeparationSpeed`, already under every airborne cap; its
	-- vertical part is policed by the vertical ceiling instead.
	return currentCap
end

-- The cap `SpeedCaps.EffectiveMaxSpeed` gives `state`, grace included, judged by the
-- bookkeeping of the transition that entered it.
function SpeedCaps.EffectiveCapFor(
	session: PlayerSession,
	state: MovementState,
	constants: EffectiveMovementConstants
): number
	local currentCap = SpeedCaps.CapForState(session, state, constants)

	-- Skips the grace below -- it's sized for an ordinary landing's brief
	-- momentum tail, not a multi-second lock.
	if state == MovementStates.HardLanding then
		return currentCap
	end

	-- `previousCap` is the full effective cap in force right before the last
	-- transition (allowances included), so landing out of a WallLeap graces
	-- the leap's real speed rather than only the bare Airborne tier.
	local previousCap = session.previousCap
	if previousCap <= currentCap then
		-- The cap went up or stayed the same -- there's no residual-momentum
		-- tail to grace here, only ever downward transitions produce one.
		return currentCap
	end

	if os.clock() - session.lastTransitionAt < SpeedCaps.LANDING_MOMENTUM_GRACE_SECONDS then
		return previousCap
	end
	return currentCap
end

function SpeedCaps.EffectiveMaxSpeed(
	session: PlayerSession,
	constants: EffectiveMovementConstants
): number
	return SpeedCaps.EffectiveCapFor(session, session.fsm.current, constants)
end

return SpeedCaps
