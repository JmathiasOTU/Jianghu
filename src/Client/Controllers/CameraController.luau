--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementCues = require(ReplicatedStorage.Shared.Presentation.MovementCues)
local CueDebounce = require(ReplicatedStorage.Shared.Presentation.CueDebounce)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)
local Spring = require(ReplicatedStorage.Shared.Util.Spring)
local MovementLife = require(script.Parent.Parent.State.MovementLife)

type MovementState = MovementStates.MovementState
type ShakeProfile = PresentationConstants.ShakeProfile

local SHIFT_LOCK_KEYS: { [Enum.KeyCode]: boolean } = {
	[Enum.KeyCode.LeftShift] = true,
	[Enum.KeyCode.RightShift] = true,
}

-- Runs right after the default camera script has placed the camera. The
-- shoulder offset and shake are pure translations in camera space, and the
-- default script rebuilds its position from the focus every frame, so
-- neither accumulates (docs/MOVEMENT_POLISH_ARCHITECTURE.md §4.2).
local RENDER_STEP_NAME = "CameraPolish"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

-- Session-long, not per life: the springs keep their motion through a
-- respawn instead of snapping back to base (§4.0).
local CameraController = {}

local fovSpring = Spring.number(
	PresentationConstants.FOVDampingRatio,
	PresentationConstants.FOVFrequency,
	PresentationConstants.BaseFOV
)
local offsetSpring = Spring.vector3(
	PresentationConstants.ShiftLockDampingRatio,
	PresentationConstants.ShiftLockInFrequency,
	Vector3.zero
)
local random = Random.new()

local shiftLocked = false
local head: BasePart? = nil
local activeShake: { profile: ShakeProfile, startedAt: number }? = nil
local shakeDebounce = CueDebounce.new()

-- Our own shift lock, replacing Roblox's default mouse lock (disabled via
-- StarterPlayer.EnableMouseLockOption in default.project.json), whose offset
-- snaps in one frame (§4.3). Facing stays with FacingController, which keys
-- off LockCenter like the camera-lock claim does.
local function setShiftLocked(locked: boolean)
	shiftLocked = locked
	offsetSpring:SetFrequency(
		if locked
			then PresentationConstants.ShiftLockInFrequency
			else PresentationConstants.ShiftLockOutFrequency
	)
	offsetSpring:SetGoal(if locked then PresentationConstants.ShiftLockOffset else Vector3.zero)
	UserInputService.MouseBehavior = if locked
		then Enum.MouseBehavior.LockCenter
		else Enum.MouseBehavior.Default
	UserInputService.MouseIcon = if locked then PresentationConstants.ShiftLockMouseIcon else ""
end

local function startShake(name: string)
	local profile = PresentationConstants.ShakeProfiles[name]
	if not profile or not shakeDebounce:TryFire(name) then
		return
	end
	activeShake = { profile = profile, startedAt = os.clock() }
end

local function sampleShake(now: number): Vector3
	local shake = activeShake
	if not shake then
		return Vector3.zero
	end
	local progress = (now - shake.startedAt) / shake.profile.DurationSeconds
	if progress >= 1 then
		activeShake = nil
		return Vector3.zero
	end
	return random:NextUnitVector() * shake.profile.Magnitude * (1 - progress) ^ 2
end

-- A shoulder offset in first person would push the camera out of the head.
local function isFirstPerson(camera: Camera): boolean
	if not head then
		return false
	end
	return head.LocalTransparencyModifier > PresentationConstants.FirstPersonHeadTransparency
		or (head.Position - camera.CFrame.Position).Magnitude
			<= PresentationConstants.FirstPersonHeadDistance
end

local function followLife(life: MovementLife.Life)
	local character = life.humanoid.Parent
	local lifeHead = character and character:FindFirstChild("Head")
	head = if lifeHead and lifeHead:IsA("BasePart") then lifeHead else nil

	life.trove:Connect(life.fsm.changed, function(next: MovementState)
		local cue = MovementCues[next]
		if cue and cue.CameraShake then
			startShake(cue.CameraShake)
		end
	end)
	life.trove:Add(function()
		head = nil
		if shiftLocked then
			setShiftLocked(false)
		end
	end)
end

local function update(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	-- Follows fsm.current rather than fsm.changed: SlideJump/WallLeap re-enter
	-- the FSM mid-handler, so change events can arrive out of order (§1).
	local life = MovementLife.Current()
	if life then
		local cue = MovementCues[life.fsm.current]
		if cue and cue.TargetFOV then
			fovSpring:SetGoal(cue.TargetFOV)
		elseif not (cue and cue.HoldsFOV) then
			fovSpring:SetGoal(PresentationConstants.BaseFOV)
		end
	end
	camera.FieldOfView = fovSpring:Update(dt)

	-- The default camera script can release the mouse on its own (e.g. after a
	-- right-drag); keep it locked while shift lock is on.
	if shiftLocked and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	local shoulder = offsetSpring:Update(dt)
	local offset = sampleShake(os.clock())
	if not isFirstPerson(camera) then
		offset += shoulder
	end
	if offset ~= Vector3.zero then
		camera.CFrame *= CFrame.new(offset)
	end
end

function CameraController.Init()
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent or not SHIFT_LOCK_KEYS[input.KeyCode] then
			return
		end
		-- Only while alive; a life's end unlocks (followLife).
		if MovementLife.Current() then
			setShiftLocked(not shiftLocked)
		end
	end)

	local current = MovementLife.Current()
	if current then
		followLife(current)
	end
	MovementLife.Started:Connect(followLife)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, update)
end

return CameraController
