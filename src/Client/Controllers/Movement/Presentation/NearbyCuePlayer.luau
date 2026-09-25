--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local MovementCues = require(ReplicatedStorage.Shared.Presentation.MovementCues)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)

local CharacterFX = require(script.Parent.CharacterFX)

type MovementState = MovementStates.MovementState

local STATE_BY_NAME: { [string]: MovementState } = {}
for state, name in pairs(MovementStateNames.DebugNames) do
	STATE_BY_NAME[name] = state
end

-- Plays another player's Nearby cue (a hard landing, a wall leap) on their
-- character, from the server's PlayMovementCue broadcast
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §5). Only the one-shot sound and
-- particle: another player's landing never shakes this camera.
local NearbyCuePlayer = {}

function NearbyCuePlayer.Play(data: { player: Player, state: MovementStateNames.DebugStateName })
	local player = data.player
	-- The server already excludes the mover, who played it locally.
	if player == Players.LocalPlayer then
		return
	end
	local state = STATE_BY_NAME[data.state]
	local cue = state and MovementCues[state]
	if not (cue and cue.Replication == "Nearby") then
		return
	end
	-- A character that hasn't streamed in yet (ARCHITECTURE §14) is routine,
	-- not an error.
	local character = player.Character
	if not character then
		return
	end

	if cue.EnterSound then
		local sounds = CharacterFX.Scan(character, cue.EnterSound)
		for _, sound in ipairs(sounds) do
			sound:Play()
		end
	end
	if cue.EnterParticle then
		local _, emitters = CharacterFX.Scan(character, cue.EnterParticle)
		local count = cue.EnterParticleCount or PresentationConstants.DefaultEmitCount
		for _, emitter in ipairs(emitters) do
			emitter:Emit(count)
		end
	end
end

return NearbyCuePlayer
