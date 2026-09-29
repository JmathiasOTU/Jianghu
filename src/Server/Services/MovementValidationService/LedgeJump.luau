--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local Sessions = require(script.Parent.Sessions)
local Context = require(script.Parent.Context)
local SpeedCaps = require(script.Parent.SpeedCaps)

type PlayerSession = Sessions.PlayerSession

-- The server's LedgeJump (docs/MovementSystem.md §4.10): inferred, never
-- claimed, like SlideJump. The mirror goes Airborne on the state label, which
-- leads the positions by 0.15-0.2 s (§9); a drop probe run then would start
-- several studs short of the edge and find ground. So a takeoff is watched
-- (armed in TransitionBookkeeping) until the position stream shows the
-- lift-off, and judged from there.
local LedgeJump = {}

-- Once per Heartbeat, after the passive mirror and the claim retries.
function LedgeJump.ResolveTakeoff(session: PlayerSession)
	local watchUntil = session.takeoffWatchUntil
	if not watchUntil then
		return
	end
	local current = session.fsm.current
	if
		os.clock() >= watchUntil
		or (current ~= MovementStates.Airborne and current ~= MovementStates.DoubleJump)
	then
		session.takeoffWatchUntil = nil
		return
	end
	-- The position stream still shows it on its feet.
	if session.supported then
		return
	end
	session.takeoffWatchUntil = nil

	local from = session.lastSupportedRoot
	local liftoffAfter = session.lastSupportedAt
	if not from or not liftoffAfter then
		return
	end
	local root = session.rootPart
	-- A walk-off never rises above where it left the ground; a jump has by the
	-- time the support probe loses the floor. Catches a jump label the mirror
	-- missed.
	if not session.takeoffJumped and root.Position.Y <= from.Position.Y then
		return
	end
	-- The last grounded sample and the first airborne one bracket the takeoff;
	-- either can be the nearer to the edge.
	local velocity = root.AssemblyLinearVelocity
	local character = session.humanoid.Parent :: Instance
	if
		not SpatialQueries.QueryLedgeDropAhead(from.Position, velocity, character)
		and not SpatialQueries.QueryLedgeDropAhead(root.Position, velocity, character)
	then
		return
	end

	-- The client's double jump after its ledge jump reached the mirror first.
	-- Ending the mirror's early gains nothing, as for a pending wall claim
	-- (§8.4): same cap, and its ceiling raise is already applied.
	if
		current == MovementStates.DoubleJump
		and not session.fsm:RequestTransition(MovementStates.Airborne, Context.Build(session))
	then
		return
	end

	local context = Context.Build(session)
	context.ledgeDropAhead = true
	local constants = context.constants
	local capBefore = SpeedCaps.EffectiveMaxSpeed(session, constants)
	if not session.fsm:RequestTransition(MovementStates.LedgeJump, context) then
		return
	end
	-- The launch is the takeoff speed plus a flat burst. The fastest the
	-- character could carry at takeoff is last Heartbeat's `carrySpeed` (cap
	-- plus the floor it stood on; the floor reads zero now it's airborne). Kept
	-- for the flight, like the other launch allowances.
	session.airborneAllowedSpeed = TraversalMath.LedgeJumpMaxHorizontalSpeed(
		math.max(capBefore, session.carrySpeed),
		constants.LedgeJumpBurstForce
	)
	session.airborneAllowanceExpiresAt = nil
	session.fsm:RequestTransition(MovementStates.Airborne, context)

	-- The burst began at the lift-off, which the position stream puts after the
	-- last grounded sample; the time since was budgeted at the old cap.
	local capAfter = SpeedCaps.EffectiveMaxSpeed(session, constants)
	if capAfter > capBefore then
		session.speedBudget += (capAfter - capBefore) * math.min(
			os.clock() - liftoffAfter,
			MovementConstants.SpeedCheckIntervalSeconds
		)
	end
end

return LedgeJump
