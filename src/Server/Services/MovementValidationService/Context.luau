--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local MovementTuningState = require(script.Parent.Parent.Parent.State.MovementTuningState)
local Sessions = require(script.Parent.Sessions)
local Probes = require(script.Parent.Probes)
local Flow = require(script.Parent.Flow)
local ClaimTiming = require(script.Parent.ClaimTiming)

type MovementContext = MovementTypes.MovementContext
type PlayerSession = Sessions.PlayerSession

-- Builds the server's own MovementContext for a session: the same shape
-- the client's CanEnter predicates read, filled only from replicated
-- state and server probes.
local Context = {}

-- The server never sees raw WASD key state (that's client-only), so it can't
-- literally reconstruct "is W held" the way InputController does. Instead this
-- mirrors the same forward/backward/strafe *classification* SprintState.Update
-- relies on, geometrically: forward/backward from facing's dot with MoveDirection
-- past a deadzone, strafeLeft/strafeRight from the sign of the analogous cross
-- product (same convention as LocomotionAnimator.resolveDirectionBucket -- positive
-- means Right). Both inputs (rootPart.CFrame, humanoid.MoveDirection) are written
-- by the network-owning client (audit M-004/M-027), so this only classifies
-- intent for the mirror's tier choices -- every cap it can unlock is still
-- enforced against real displacement by `SpeedCheck.Enforce`.
--
-- Forward/backward use a deadzone (this session's effective
-- SprintForwardDeadzone, docs/MovementSystem.md §10 -- MovementConstants' shipped
-- 0.5 unless a developer is live-tuning it) rather than a bare `> 0`/`< 0`
-- zero-crossing (hardened 2026-09-13): real WASD input only ever produces a
-- facing/MoveDirection angle of 0/45/90+ degrees, so the shipped deadzone
-- (comfortably below cos 45° ≈ 0.707) never affects legitimate diagonal
-- Sprint-holding -- it only closes off a spoofed `MoveDirection` sitting at a
-- razor-thin positive angle (e.g. 89°) that used to satisfy `> 0` and dodge
-- the Sprint->Run demotion while moving almost entirely sideways.
local function classifyMoveIntent(
	facing: Vector3,
	moveDirection: Vector3,
	deadzone: number
): (boolean, boolean, boolean, boolean)
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	local flatMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flatFacing.Magnitude == 0 or flatMove.Magnitude == 0 then
		return false, false, false, false
	end
	flatFacing = flatFacing.Unit
	flatMove = flatMove.Unit

	local forwardComponent = flatFacing:Dot(flatMove)
	local rightComponent = flatMove:Cross(flatFacing).Y

	return forwardComponent > deadzone,
		forwardComponent < -deadzone,
		rightComponent < 0,
		rightComponent > 0
end

local function classifySession(
	session: PlayerSession,
	deadzone: number
): (boolean, boolean, boolean, boolean)
	return classifyMoveIntent(
		session.rootPart.CFrame.LookVector,
		session.humanoid.MoveDirection,
		deadzone
	)
end

-- Once per Heartbeat, before the mirror (docs/MovementSystem.md §8.1).
-- MoveDirection is a Humanoid property and reaches the server about
-- 0.15-0.2 s ahead of the facing it pairs with, which rides the position
-- stream (the same measured ordering as the state label, §9). A camera turn
-- while holding W then briefly reads as a strafe: a 2026-09-28 capture showed
-- one 0.46 reading demote a held Sprint to Run. So a forward reading counts
-- for one `ClaimTiming.ClaimLagSeconds` after it was last seen, the window
-- already sized for that ordering; a real strafe or backpedal outlasts it.
function Context.RecordForward(session: PlayerSession)
	local constants = MovementTuningState.GetEffective(session.player)
	local forward = classifySession(session, constants.SprintForwardDeadzone)
	if forward then
		session.forwardSeenAt = os.clock()
	end
end

-- The context a mirrored landing resolves with. A crouch level is a claim, and
-- claims lead the position stream the landing is read from: a Ctrl press just
-- after the client touched down (a quick hop into a slide) reached the server
-- before its own landing and resolved CrouchWalk where the client had landed
-- in Sprint, then slid (2026-09-28 capture). So a crouch change newer than
-- one claim lag applies after the landing, on the next Heartbeat, not to it.
function Context.ForLanding(session: PlayerSession, context: MovementContext): MovementContext
	local changedAt = session.crouchChangedAt
	if not changedAt or os.clock() - changedAt > ClaimTiming.ClaimLagSeconds(session) then
		return context
	end
	local landing = table.clone(context)
	landing.crouchHeld = session.crouchHeldBefore
	return landing
end

-- `constants` is this session's EFFECTIVE tuning (docs/MovementSystem.md §10) --
-- read fresh from MovementTuningState on every call rather than cached on the
-- session, so a live override change is picked up on the very next Heartbeat
-- with no extra invalidation bookkeeping. StateRules.CanEnter (shared with the
-- client) reads SprintThresholdSeconds off this same field, never off
-- MovementConstants directly, so the two can never disagree about the number
-- actually in effect for this player.
function Context.Build(session: PlayerSession): MovementContext
	local constants = MovementTuningState.GetEffective(session.player)

	local runDuration = if session.fsm.current == MovementStates.Run and session.runEnteredAt
		then os.clock() - (session.runEnteredAt :: number)
		else nil

	local humanoidState = session.humanoid:GetState()
	local moveDirection = session.humanoid.MoveDirection
	local facing = session.rootPart.CFrame.LookVector
	local forward, backward, strafeLeft, strafeRight =
		classifyMoveIntent(facing, moveDirection, constants.SprintForwardDeadzone)
	local forwardSeenAt = session.forwardSeenAt
	if
		not forward
		and forwardSeenAt
		and os.clock() - forwardSeenAt <= ClaimTiming.ClaimLagSeconds(session)
	then
		forward = true
	end

	return {
		moveIntent = {
			direction = moveDirection,
			forward = forward,
			backward = backward,
			strafeLeft = strafeLeft,
			strafeRight = strafeRight,
		},
		grounded = Probes.IsGrounded(session),
		jumping = humanoidState == Enum.HumanoidStateType.Jumping,
		crouchHeld = session.crouchHeld,
		doubleJumpUsed = session.doubleJumpUsed,
		runDuration = runDuration,
		preAirborneLocomotion = session.preAirborneLocomotion,
		fallHeight = if session.peakHeight
			then session.peakHeight - session.rootPart.Position.Y
			else nil,
		horizontalVelocity = Vector3.new(
			session.rootPart.AssemblyLinearVelocity.X,
			0,
			session.rootPart.AssemblyLinearVelocity.Z
		),
		-- The server's OWN throttled probe (docs/MovementSystem.md §4.5/§8.4, `Probes.UpdateWallRunQuery`
		-- below) -- never anything the client reports.
		wallRunQuery = session.wallRunQuery,
		-- The server's OWN throttled probe (docs/MovementSystem.md §4.6/§8.4,
		-- `Probes.UpdateWallClingQuery` below) -- never anything the client reports.
		wallClingQuery = session.wallClingQuery,
		-- Real replicated `rootPart.CFrame.LookVector` -- reuses the same
		-- `facing` value already computed above for `classifyMoveIntent`,
		-- never a second read.
		facingDirection = facing,
		wallClingLockoutUntil = session.wallClingLockoutUntil,
		wallClingBoostUsed = session.wallClingBoostUsed,
		wallClingElapsed = if session.fsm.current == MovementStates.WallCling
				and session.wallClingEnteredAt
			then os.clock() - session.wallClingEnteredAt
			else nil,
		lastWallLeapWall = session.lastWallLeapWall,
		-- The server's own ledge probe (`Probes.UpdateLedgeQuery`), claim-time only.
		ledge = session.ledgeQuery,
		lastVaultAt = session.lastVaultAt,
		-- Still an open design decision (docs/MovementSystem.md §13/§2) --
		-- "always available" until a real Qinggong/stamina resource exists,
		-- same placeholder the client uses.
		qinggong = math.huge,
		-- Landing-resume fix, hardened 2026-09-18 (see MovementTypes.luau's
		-- own field comment). From the client's CameraLocked/CameraUnlocked
		-- level claims (audit M-020), not `Humanoid.AutoRotate`: the client
		-- writes that property locally and it never replicated, so the server
		-- always read "unlocked". Lying "unlocked" only selects the lenient
		-- landing path this used to take for everyone; the speed cap still
		-- applies regardless. A new lock counts one claim lag after its claim:
		-- the claim leads the facing it snaps (position stream), and read
		-- against the old unlocked facing it demoted a held Sprint to Run
		-- (2026-09-28). Unlocking applies at once, as the lenient reading.
		cameraLocked = session.cameraLocked
			and session.cameraLockedAt ~= nil
			and os.clock() - session.cameraLockedAt >= ClaimTiming.ClaimLagSeconds(session),
		flowMultiplier = Flow.Multiplier(session, constants),
		constants = constants,
	}
end

return Context
