--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)
local CollisionGroups = require(ReplicatedStorage.Shared.Movement.CollisionGroups)

local MirrorStateChanged = require(script.Parent.Parent.Parent.Events.MirrorStateChanged)
local MovementTuningState = require(script.Parent.Parent.Parent.State.MovementTuningState)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local SpeedCaps = require(script.Parent.SpeedCaps)

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

	-- The client enters a slide at its real speed x SlideEntrySpeedMultiplier,
	-- clamped to `SpeedCaps.SlideCeiling` (SlideState.Enter). The server's bound on
	-- that real speed is the effective cap it allowed in `previous`, grace
	-- included, so it's read before this handler moves the grace on.
	if next == MovementStates.Slide then
		session.slideEntrySpeed = math.min(
			SpeedCaps.EffectiveCapFor(session, previous, constants),
			constants.SprintSpeed
		) * constants.SlideEntrySpeedMultiplier
	end

	-- Landing-momentum grace bookkeeping (see `SpeedCaps.EffectiveMaxSpeed`) --
	-- records the full cap that applied in `previous`, BEFORE this
	-- handler's own landing bookkeeping below clears any allowance.
	session.previousCap = SpeedCaps.CapForState(session, previous, constants)
	session.previousState = previous
	session.lastTransitionAt = now

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
		then
			session.peakHeight = rootPart.Position.Y
		end
	elseif GROUNDED_STATES[next] then
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
