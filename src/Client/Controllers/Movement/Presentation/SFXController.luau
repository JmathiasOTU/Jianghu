--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementCues = require(ReplicatedStorage.Shared.Presentation.MovementCues)
local CueDebounce = require(ReplicatedStorage.Shared.Presentation.CueDebounce)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)

local CharacterMover = require(script.Parent.Parent.Core.CharacterMover)
local CharacterFX = require(script.Parent.CharacterFX)

type MovementState = MovementStates.MovementState

export type SFXController = {
	Destroy: (self: SFXController) -> (),
}

local SFXController = {}
SFXController.__index = SFXController

-- The walk-cycle loop Roblox's default RbxCharacterSounds script puts on the
-- root part; muted on this character so it doesn't double our footsteps. Its
-- other sounds (jump, land, swim, climb) are left alone.
local DEFAULT_RUNNING_SOUND_NAME = "Running"

-- Plays the local player's movement sounds from MovementCues
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §3). Reads the FSM, never writes it.
-- One-shots fire on fsm.changed; the loop follows fsm.current, since
-- SlideJump/WallLeap re-enter the FSM mid-handler and change events can
-- arrive out of order (§1).
function SFXController.new(
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<
		MovementState,
		MovementTypes.MovementContext
	>,
	characterMover: CharacterMover.CharacterMover,
	fx: CharacterFX.CharacterFX
): SFXController
	local self = setmetatable({}, SFXController) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._fsm = fsm
	self._characterMover = characterMover
	self._fx = fx
	self._debounce = CueDebounce.new()
	self._random = Random.new()
	self._activeLoop = nil :: string?
	self._strideAccumulated = 0
	self._footIndex = 0
	-- Each footstep Sound's authored PlaybackSpeed, before pitch jitter.
	self._basePlaybackSpeed = setmetatable({}, { __mode = "k" }) :: { [Sound]: number }

	self._trove:Connect(fsm.changed, function(next: MovementState)
		-- A shorter stride must not fire early off the previous state's distance.
		self._strideAccumulated = 0
		local cue = MovementCues[next]
		if cue and cue.EnterSound and self._debounce:TryFire(cue.EnterSound) then
			for _, sound in ipairs(fx:GetSounds(cue.EnterSound)) do
				sound:Play()
			end
		end
	end)

	self._trove:Connect(RunService.Heartbeat, function(dt: number)
		self:_updateLoop()
		self:_updateFootsteps(dt)
	end)

	local function muteDefaultRunning(child: Instance)
		if child.Name == DEFAULT_RUNNING_SOUND_NAME and child:IsA("Sound") then
			child.Volume = 0
		end
	end
	for _, child in ipairs(rootPart:GetChildren()) do
		muteDefaultRunning(child)
	end
	self._trove:Connect(rootPart.ChildAdded, muteDefaultRunning)

	return self
end

function SFXController:_setLoopPlaying(name: string, playing: boolean)
	for _, sound in ipairs(self._fx:GetSounds(name)) do
		if playing then
			sound.Looped = true
			sound:Play()
		else
			sound:Stop()
		end
	end
end

function SFXController:_updateLoop()
	local cue = MovementCues[self._fsm.current]
	local wanted = cue and cue.LoopSound
	if wanted == self._activeLoop then
		return
	end
	if self._activeLoop then
		self:_setLoopPlaying(self._activeLoop, false)
	end
	self._activeLoop = wanted
	if wanted then
		self:_setLoopPlaying(wanted, true)
	end
end

-- <set><floor material> ("FootstepConcrete"); for a material the pack has
-- no sound for, its alias ("FootstepGrass" on Mud), then the default
-- material, then a plain <set> sound.
function SFXController:_findFootstepSounds(set: string): { Sound }
	local material = self._humanoid.FloorMaterial.Name
	local candidates = { set .. material }
	local alias = PresentationConstants.FootstepMaterialAliases[material]
	if alias then
		table.insert(candidates, set .. alias)
	end
	table.insert(candidates, set .. PresentationConstants.FootstepDefaultMaterial)
	table.insert(candidates, set)
	for _, name in ipairs(candidates) do
		local sounds = self._fx:GetSounds(name)
		if #sounds > 0 then
			return sounds
		end
	end
	return {}
end

-- A step every FootstepStrideStuds actually travelled, so cadence follows
-- real speed without a per-tier timer (§3.2). Alternates between the
-- instances found (one per foot, if both feet carry the set).
function SFXController:_updateFootsteps(dt: number)
	local cue = MovementCues[self._fsm.current]
	local stride = cue and cue.FootstepStrideStuds
	if not (cue and cue.FootstepSound and stride and self._characterMover:IsGrounded()) then
		self._strideAccumulated = 0
		return
	end

	self._strideAccumulated += self._characterMover:GetHorizontalVelocity().Magnitude * dt
	if self._strideAccumulated < stride then
		return
	end
	self._strideAccumulated = 0

	local sounds = self:_findFootstepSounds(cue.FootstepSound)
	if #sounds == 0 then
		return
	end
	self._footIndex = self._footIndex % #sounds + 1
	local sound = sounds[self._footIndex]
	-- One step per stride; a pack saved with looping sounds would otherwise
	-- keep playing between strides.
	sound.Looped = false
	local basePlaybackSpeed = self._basePlaybackSpeed[sound] or sound.PlaybackSpeed
	self._basePlaybackSpeed[sound] = basePlaybackSpeed
	local jitter = PresentationConstants.FootstepPitchJitter
	sound.PlaybackSpeed = basePlaybackSpeed * (1 + self._random:NextNumber(-jitter, jitter))
	sound:Play()
end

function SFXController:Destroy()
	if self._activeLoop then
		self:_setLoopPlaying(self._activeLoop, false)
		self._activeLoop = nil
	end
	self._trove:Destroy()
end

return SFXController
