--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementAnimations = require(ReplicatedStorage.Shared.Constants.MovementAnimations)

local InputController = require(script.Parent.Parent.InputController)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

local FADE_TIME = 0.15

local DIRECTION_NAMES: { string } =
	{ "Forward", "ForwardRight", "Right", "BackRight", "Back", "BackLeft", "Left", "ForwardLeft" }

export type LocomotionAnimator = {
	Destroy: (self: LocomotionAnimator) -> (),
}

local LocomotionAnimator = {}
LocomotionAnimator.__index = LocomotionAnimator

-- Facing-relative angle from `facing` to `moveDirection`, bucketed into one of the
-- 8 directions named above. 0deg (Forward) means moving the way you're facing;
-- positive angles go clockwise (docs/MOVEMENT.md §1: input direction relative to
-- facing selects the animation, not world-space direction).
local function resolveDirectionBucket(facing: Vector3, moveDirection: Vector3): string
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	local flatMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flatFacing.Magnitude == 0 or flatMove.Magnitude == 0 then
		return "Forward"
	end
	flatFacing = flatFacing.Unit
	flatMove = flatMove.Unit

	local cross = flatFacing:Cross(flatMove)
	local angle = math.atan2(cross.Y, flatFacing:Dot(flatMove))
	local degrees = math.deg(angle)
	if degrees < 0 then
		degrees += 360
	end

	local index = math.floor((degrees + 22.5) / 45) % 8
	return DIRECTION_NAMES[index + 1]
end

local function loadTrack(animator: Animator, id: string?, trove: Trove.Trove): AnimationTrack?
	if not id or id == "" then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = id
	local track = trove:Add(animator:LoadAnimation(animation), "Destroy")
	animation:Destroy()
	return track
end

-- Picks/blends among the 8 directional Walk/Run anims from (facing-relative input
-- angle, current state); reads the FSM and InputController, never writes to either
-- (docs/MOVEMENT.md §1/§3). "Blends" here means a simple crossfade between whichever
-- single track is currently selected and the next -- not a weighted multi-track
-- blend space. Revisit once real animations exist and playtesting says a discrete
-- switch-with-fade isn't smooth enough.
function LocomotionAnimator.new(
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	inputController: InputController.InputController
): LocomotionAnimator
	local self = setmetatable({}, LocomotionAnimator) :: any
	self._trove = Trove.new()
	self._rootPart = rootPart
	self._fsm = fsm
	self._inputController = inputController
	self._currentKey = nil :: string?

	local animator = humanoid:WaitForChild("Animator") :: Animator

	self._tracks = {} :: { [string]: AnimationTrack? }
	self._tracks.Idle = loadTrack(animator, MovementAnimations.Idle, self._trove)
	self._tracks.Sprint = loadTrack(animator, MovementAnimations.Sprint, self._trove)
	for _, direction in DIRECTION_NAMES do
		self._tracks["Walk_" .. direction] = loadTrack(animator, MovementAnimations.Walk[direction], self._trove)
		self._tracks["Run_" .. direction] = loadTrack(animator, MovementAnimations.Run[direction], self._trove)
	end

	self._trove:Connect(RunService.RenderStepped, function()
		self:_update()
	end)

	return self
end

function LocomotionAnimator:_update()
	local state = self._fsm.current
	local key: string? = nil

	if state == MovementStates.Idle then
		key = "Idle"
	elseif state == MovementStates.Sprint then
		key = "Sprint"
	elseif state == MovementStates.Walk or state == MovementStates.Run then
		local moveIntent = self._inputController:GetMoveIntent()
		if moveIntent.direction.Magnitude > 0 then
			local facing = self._rootPart.CFrame.LookVector
			local bucket = resolveDirectionBucket(facing, moveIntent.direction)
			key = (if state == MovementStates.Walk then "Walk_" else "Run_") .. bucket
		end
	end
	-- Airborne, or Walk/Run with no move direction this frame: key stays nil,
	-- fading out whatever was last playing. Jump/fall animations aren't part of
	-- this pass -- add an Airborne clip here once one exists.

	self:_playKey(key)
end

function LocomotionAnimator:_playKey(key: string?)
	if key == self._currentKey then
		return
	end
	self._currentKey = key

	for trackKey, track in self._tracks do
		if track and trackKey ~= key and track.IsPlaying then
			track:Stop(FADE_TIME)
		end
	end

	local nextTrack = key and self._tracks[key]
	if nextTrack and not nextTrack.IsPlaying then
		nextTrack:Play(FADE_TIME)
	end
end

function LocomotionAnimator:Destroy()
	self._trove:Destroy()
end

return LocomotionAnimator
