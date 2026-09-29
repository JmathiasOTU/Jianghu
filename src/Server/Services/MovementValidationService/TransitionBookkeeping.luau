--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)
local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)

local MirrorStateChanged = require(script.Parent.Parent.Parent.Events.MirrorStateChanged)
local MovementTuningState = require(script.Parent.Parent.Parent.State.MovementTuningState)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local SpeedCaps = require(script.Parent.SpeedCaps)
local Flow = require(script.Parent.Flow)
local Context = require(script.Parent.Context)
local ClaimTiming = require(script.Parent.ClaimTiming)

type MovementState = MovementStates.MovementState
type PlayerSession = Sessions.PlayerSession

-- Session bookkeeping on each mirrored transition: the landing grace
-- snapshot, allowance and lockout clears, fall height, the HardLanding
-- lock, the collision group, and MirrorStateChanged for other services.
local TransitionBookkeeping = {}

-- Grounded-family states (docs/MovementSystem.md §4.4 rework) -- same "which states
-- count as grounded" question `session.peakHeight`'s seed/clear edge (below,
-- in `createSession`'s `fsm.changed` handler) needs answered server-side. See
-- Shared/FSM/MovementStateGroups.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- client's own GROUNDED_STATES in Movement/init.luau).
local GROUNDED_STATES = MovementStateGroups.Grounded

-- Takeoffs a LedgeJump can come from (docs/MovementSystem.md §4.10): the
-- speed tiers, and a slide (a slide jump, or one whose jump frame the mirror
-- missed).
local LEDGE_JUMP_TAKEOFFS: { [MovementState]: boolean } = {
	[MovementStates.Run] = true,
	[MovementStates.Sprint] = true,
	[MovementStates.Slide] = true,
	[MovementStates.SlideJump] = true,
}

-- Run on every transition of a session's mirrored FSM, from its
-- `fsm.changed` connection (createSession in init.luau).
function TransitionBookkeeping.OnChanged(
	session: PlayerSession,
	next: MovementState,
	previous: MovementState
)
	local player = session.player
	local humanoid = session.humanoid
	local rootPart = session.rootPart
	local now = os.clock()
	local constants = MovementTuningState.GetEffective(player)

	if DebugFlags.LANDING_DEBUG_LOGGING then
		local names = MovementStateNames.DebugNames
		local context = Context.Build(session)
		local pre = session.preAirborneLocomotion
		print(
			string.format(
				"[Transition] server %s -> %s pre=%s fwd=%s back=%s locked=%s crouch=%s grounded=%s facingDotMove=%.2f",
				names[previous],
				names[next],
				if pre then names[pre] else "nil",
				tostring(context.moveIntent.forward),
				tostring(context.moveIntent.backward),
				tostring(context.cameraLocked),
				tostring(context.crouchHeld),
				tostring(context.grounded),
				if context.moveIntent.direction.Magnitude > 0
					then rootPart.CFrame.LookVector:Dot(context.moveIntent.direction.Unit)
					else 0
			)
		)
	end

	-- The client enters a slide at its real speed x SlideEntrySpeedMultiplier,
	-- clamped to `SpeedCaps.SlideCeiling` (SlideState.Enter). The server's bound on
	-- that real speed is the effective cap it allowed in `previous`, grace
	-- included, so it's read before this handler moves the grace on. Flow
	-- raises the clamp like the client's (docs/MovementSystem.md §8.2).
	if next == MovementStates.Slide then
		session.slideEntryLocomotion = previous
		session.slideEntrySpeed = math.min(
			SpeedCaps.EffectiveCapFor(session, previous, constants),
			constants.SprintSpeed * Flow.Multiplier(session, constants)
		) * constants.SlideEntrySpeedMultiplier
	end

	-- Every entry into Run restarts the dwell toward Sprint, as RunState.Enter
	-- does client-side; a landing that resumes Run used to keep the stale
	-- clock (2026-09-28 capture). The mirror sees that landing one claim lag
	-- after the client did (0.13-0.42 s in the same capture), so its clock is
	-- backdated by that much; the Sprint claim buffer covers the rest. A Run
	-- claim then re-stamps it with its own ping backdate.
	if next == MovementStates.Run then
		session.runEnteredAt = now - ClaimTiming.ClaimLagSeconds(session)
	end

	-- Landing-momentum grace bookkeeping (see `SpeedCaps.EffectiveMaxSpeed`) --
	-- records the full cap that applied in `previous`, BEFORE this
	-- handler's own landing bookkeeping below clears any allowance.
	session.previousCap = SpeedCaps.CapForState(session, previous, constants)
	session.previousState = previous
	session.lastTransitionAt = now

	-- After the snapshot above, so the grace never records a Flow gain the
	-- previous state didn't have.
	Flow.OnTransition(session, next, constants)

	-- WallRun and WallCling both replace the character's velocity outright
	-- (full-force override), so a WallLeap allowance carried in from an
	-- earlier leap no longer describes anything physical -- and left in
	-- place it would lift WallCling's zero-drift cap to leap speed.
	if next == MovementStates.WallRun or next == MovementStates.WallCling then
		session.airborneAllowedSpeed = nil
	end

	-- Post-boost re-grab cooldown, server-owned (audit M-038): the client
	-- applies it on WallBoost's own Exit, so the server applies it on the
	-- same edge of its own mirror.
	if previous == MovementStates.WallBoost then
		session.wallClingLockoutUntil = now + constants.WallClingPostBoostCooldown
	end

	-- HardLanding fall-height bookkeeping (docs/MovementSystem.md §4.4 rework) --
	-- mirrors Movement/init.luau's own client-side edge exactly: seeded on
	-- the real takeoff edge (`next == Airborne`, excluding the Airborne <->
	-- DoubleJump hop so the peak survives it), cleared the instant a
	-- landing actually resolves.
	if next == MovementStates.Airborne then
		if
			previous ~= MovementStates.DoubleJump
			and previous ~= MovementStates.WallRun
			and previous ~= MovementStates.WallLeap
			and previous ~= MovementStates.WallCling
			and previous ~= MovementStates.WallBoost
			and previous ~= MovementStates.Vault
			and previous ~= MovementStates.LedgeJump
		then
			session.peakHeight = rootPart.Position.Y
		end
		-- The label that took the mirror airborne leads the positions (§9),
		-- so a possible LedgeJump is judged once they show the lift-off
		-- (`LedgeJump.ResolveTakeoff`), within one claim lag.
		if LEDGE_JUMP_TAKEOFFS[previous] then
			session.takeoffWatchUntil = now + ClaimTiming.ClaimLagSeconds(session)
			session.takeoffJumped = previous == MovementStates.SlideJump
				or humanoid:GetState() == Enum.HumanoidStateType.Jumping
		end
	elseif GROUNDED_STATES[next] then
		session.takeoffWatchUntil = nil
		-- On every grounded entry, like the client's `fsm.changed` handler, not
		-- only in the mirror's landing branches: a stale Sprint takeoff tier
		-- would let a later Sprint claim skip the Run dwell.
		session.doubleJumpUsed = false
		session.preAirborneLocomotion = nil
		session.peakHeight = nil
		session.groundLaunchSpeed = nil
		session.groundRaise = nil
		-- WallLeap ceiling bookkeeping (playtest fix 2026-09-18) -- cleared
		-- the instant this session actually lands, same edge as
		-- `peakHeight` just above, so an elevated post-leap speed
		-- allowance can never linger as a standing exploit once back on
		-- the ground.
		session.airborneAllowedSpeed = nil
		-- WallCling/WallBoost bookkeeping (docs/MovementSystem.md §4.6/
		-- §11.5), same landing edge as the two clears just above.
		session.lastWallLeapWall = nil
		session.wallBoostStartedAt = nil
	end

	-- HardLanding lock deadline (docs/MovementSystem.md §4.4 rework) -- mirrors
	-- the client's own `HardLandingState.Enter` timestamp exactly, off
	-- this session's own EFFECTIVE tuning (never a client-claimed
	-- duration) so `Mirror.PassiveTransitions`'s own HardLanding branch
	-- knows exactly when the client-side lock is expected to release.
	if next == MovementStates.HardLanding then
		session.hardLandingLockUntil = now + constants.HardLandingDurationSeconds
		session.hardLandingLockPosition = rootPart.Position
	elseif previous == MovementStates.HardLanding then
		session.hardLandingLockPosition = nil
	end

	-- Passability (docs/MovementSystem.md §4.2): the SERVER's own copy, keyed off
	-- its own mirrored state -- never the client's. This is the
	-- authoritative copy every OTHER client's view of this character (and
	-- the server's own collision awareness) is built from; the owning
	-- client's identical, independent write in Movement/init.luau is only
	-- for that client's own local physics simulation feel.
	CollisionGroups.Apply(humanoid.Parent :: Model, next)

	if DebugFlags.SPEED_SANITY_DEBUG_LOGGING then
		local previousCap = session.previousCap
		local newCap = SpeedCaps.CapForState(session, next, constants)
		if previousCap > newCap then
			print(
				string.format(
					"[SpeedSanity] %s %s -> %s, cap %.1f -> %.1f, grace window started",
					player.Name,
					tostring(previous),
					tostring(next),
					previousCap,
					newCap
				)
			)
		end
	end

	MirrorStateChanged:Fire(player, next, previous)
end

return TransitionBookkeeping
