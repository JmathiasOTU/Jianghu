--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local MovementTuningState = require(script.Parent.Parent.Parent.State.MovementTuningState)
local Sessions = require(script.Parent.Sessions)
local Probes = require(script.Parent.Probes)

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
		crouchHeld = session.crouchHeld and not session.crouchSuppressed,
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
		-- applies regardless.
		cameraLocked = session.cameraLocked,
		constants = constants,
	}
end

return Context
