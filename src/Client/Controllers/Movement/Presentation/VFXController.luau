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

local CharacterFX = require(script.Parent.CharacterFX)

type MovementState = MovementStates.MovementState

export type VFXController = {
	Destroy: (self: VFXController) -> (),
}

local VFXController = {}
VFXController.__index = VFXController

-- Drives the local player's movement particles from MovementCues
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §3). Same shape as SFXController:
-- bursts on fsm.changed, the loop follows fsm.current (§1).
function VFXController.new(
	fsm: StateMachine.StateMachine<
		MovementState,
		MovementTypes.MovementContext
	>,
	fx: CharacterFX.CharacterFX
): VFXController
	local self = setmetatable({}, VFXController) :: any
	self._trove = Trove.new()
	self._fsm = fsm
	self._fx = fx
	self._debounce = CueDebounce.new()
	self._activeLoop = nil :: string?

	self._trove:Connect(fsm.changed, function(next: MovementState)
		local cue = MovementCues[next]
		if cue and cue.EnterParticle and self._debounce:TryFire(cue.EnterParticle) then
			local count = cue.EnterParticleCount or PresentationConstants.DefaultEmitCount
			for _, emitter in ipairs(fx:GetEmitters(cue.EnterParticle)) do
				emitter:Emit(count)
			end
		end
	end)

	self._trove:Connect(RunService.Heartbeat, function()
		self:_updateLoop()
	end)

	return self
end

function VFXController:_setLoopEnabled(name: string, enabled: boolean)
	for _, emitter in ipairs(self._fx:GetEmitters(name)) do
		emitter.Enabled = enabled
	end
end

function VFXController:_updateLoop()
	local cue = MovementCues[self._fsm.current]
	local wanted = cue and cue.LoopParticle
	if wanted == self._activeLoop then
		return
	end
	if self._activeLoop then
		self:_setLoopEnabled(self._activeLoop, false)
	end
	self._activeLoop = wanted
	if wanted then
		self:_setLoopEnabled(wanted, true)
	end
end

function VFXController:Destroy()
	if self._activeLoop then
		self:_setLoopEnabled(self._activeLoop, false)
		self._activeLoop = nil
	end
	self._trove:Destroy()
end

return VFXController
