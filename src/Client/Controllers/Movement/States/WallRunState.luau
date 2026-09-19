--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Locked-tangent skim along a wall (Wall Run & Leap Mechanic Guideline §3) --
-- server-claimed validation (§6) lands separately; this is the client-
-- predicted physics + FSM wiring only. Tangent/normal are locked at Entry and
-- never recomputed mid-run (§0's corner-handling decision) -- only the LIVE
-- wall query's normal/position feed the cling correction and the corner
-- deviation check below, never the horizontal direction itself.
local WallRunState = {}

WallRunState.CanEnter = StateRules.CanEnter[MovementStates.WallRun]

-- Module-scope, not per-context -- same "one local-player FSM, safely tracks
-- the single in-flight run's own entry snapshot" pattern DoubleJumpState's
-- `enteredAt` already established.
local entryNormal: Vector3? = nil
local entryTangent: Vector3? = nil
local entryTimestamp: number? = nil
local entrySide: ("Left" | "Right")? = nil

-- Exposed the same way SlideState.GetCurrentSpeed/GetCurrentDirection
-- already are (docs/MOVEMENT.md §9/§12): a sibling state (WallLeapState)
-- reads these off `context`, never by requiring this module directly --
-- Movement/init.luau's buildContext is the one place that wires a state's
-- own internal value onto ClientMovementContext for another state to read.
-- No GetEntrySpeed anymore (removed 2026-09-18, WallLeap redesign) -- the
-- leap now reads REAL current velocity off CharacterMover instead of this
-- snapshot, since the run's speed never actually decays/changes mid-hold.
-- `GetEntrySide` (added 2026-09-18 for animation wiring) is read directly by
-- `LocomotionAnimator` (a Presentation-layer accessor, same as
-- `CharacterMover:IsGrounded`/`IsJumping`) rather than via `context` -- the
-- animator runs off `RunService.RenderStepped`, not the Heartbeat-driven
-- `ClientMovementContext`, so it has no context object of its own to read
-- this off.
function WallRunState.GetEntryNormal(): Vector3?
	return entryNormal
end

function WallRunState.GetEntryTangent(): Vector3?
	return entryTangent
end

function WallRunState.GetEntrySide(): ("Left" | "Right")?
	return entrySide
end

-- Full maxForce on all three axes (unlike DoubleJump's Y-only or Slide's
-- XZ-only) -- WallRun owns vertical AND horizontal simultaneously, since both
-- are dictated by the wall, not by Humanoid.WalkSpeed.
local FULL_FORCE = Vector3.new(math.huge, math.huge, math.huge)

-- Locked tangent (constants.WallRunSpeed) + a clamped P-controller cling
-- correction along the LIVE wall normal (guideline §3's "Cling Distance"
-- subsection) -- one SetVelocityOverride call, not a separate constraint.
local function applyVelocity(context: ClientMovementContext, wallQuery: SpatialQueries.WallRunQueryResult)
	local tangent = entryTangent :: Vector3
	local horizontal = tangent * context.constants.WallRunSpeed

	local currentOffset = (context.characterMover:GetPosition() - wallQuery.position):Dot(wallQuery.normal)
	local offsetError = context.constants.WallRunClingDistance - currentOffset
	local clingCorrection = wallQuery.normal
		* math.clamp(
			offsetError * context.constants.WallRunClingCorrectionRate,
			-context.constants.WallRunClingMaxCorrectionSpeed,
			context.constants.WallRunClingMaxCorrectionSpeed
		)

	local velocity = Vector3.new(
		horizontal.X + clingCorrection.X,
		-context.constants.WallRunSinkSpeed,
		horizontal.Z + clingCorrection.Z
	)
	context.characterMover:SetVelocityOverride(velocity, FULL_FORCE)
end

-- CanEnter already guarantees `context.wallRunQuery` is non-nil at the moment
-- this fires (same context object RequestTransition just validated) -- the
-- `if not wallQuery` below is defensive typing, not an expected path.
function WallRunState.Enter(context: ClientMovementContext)
	local wallQuery = context.wallRunQuery
	if not wallQuery then
		return
	end

	entryNormal = wallQuery.normal
	entryTangent = TraversalMath.WallRunTangent(wallQuery.normal, context.horizontalVelocity)
	entryTimestamp = os.clock()
	entrySide = wallQuery.side

	-- One-time position snap (guideline §3's cling distance) -- corrects
	-- whatever the entry approach angle/distance was to a flush
	-- WallRunClingDistance offset, before the first velocity override is even
	-- applied.
	local currentOffset = (context.characterMover:GetPosition() - wallQuery.position):Dot(wallQuery.normal)
	local correction = wallQuery.normal * (context.constants.WallRunClingDistance - currentOffset)
	context.characterMover:NudgeIntoWall(correction)

	-- Playtest fix 2026-09-18: without this, spinning the camera in Shift
	-- Lock or holding WASD kept rotating the character mid-run (FacingController's
	-- own per-frame camera/AutoRotate logic doesn't know or care what FSM state
	-- is active) -- knocking a run off its locked tangent early and, once
	-- animations land, looking ridiculous. Facing follows the locked entry
	-- tangent itself, not the live (possibly corner-adjusted) one -- the run's
	-- horizontal direction never changes mid-hold either (see applyVelocity),
	-- so facing shouldn't either. Released in Exit below.
	context.facingController:SetLockDirection(entryTangent)

	applyVelocity(context, wallQuery)
end

-- Sustain check, every tick (guideline §3): wall lost, corner/curve exceeded
-- the locked-tangent budget, or the duration cap -- all three snap off
-- cleanly into Airborne, no continuous re-steering. A mid-run landing
-- resolves directly via the same AirborneState.ResolveLandingTarget every
-- other airborne-family state already reuses.
function WallRunState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	local wallQuery = context.wallRunQuery
	if not wallQuery then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if
		TraversalMath.AngleBetween(wallQuery.normal, entryNormal :: Vector3)
		> context.constants.WallRunMaxNormalDeviationDegrees
	then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if os.clock() - (entryTimestamp :: number) >= context.constants.WallRunMaxDurationSeconds then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	applyVelocity(context, wallQuery)
end

function WallRunState.Exit(context: ClientMovementContext)
	context.characterMover:ClearVelocityOverride()
	context.facingController:SetLockDirection(nil)
	entryNormal = nil
	entryTangent = nil
	entryTimestamp = nil
	entrySide = nil
end

return WallRunState
