--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)

export type CharacterFX = {
	GetSounds: (self: CharacterFX, name: string) -> { Sound },
	GetEmitters: (self: CharacterFX, name: string) -> { ParticleEmitter },
	Destroy: (self: CharacterFX) -> (),
}

local CharacterFX = {}
CharacterFX.__index = CharacterFX

local NONE: { any } = table.freeze({})

local function insert(index: { [string]: { any } }, instance: Instance)
	local list = index[instance.Name]
	if not list then
		list = {}
		index[instance.Name] = list
	end
	table.insert(list, instance)
end

local function remove(index: { [string]: { any } }, instance: Instance)
	local list = index[instance.Name]
	local position = list and table.find(list, instance)
	if list and position then
		table.remove(list, position)
	end
end

-- Cue name -> the Sounds/ParticleEmitters the server mounted on this
-- character (docs/MOVEMENT_POLISH_ARCHITECTURE.md §2). Kept current from
-- DescendantAdded/Removing, so it doesn't matter whether the mount
-- replicates before or after this starts listening. Sounds and emitters are
-- indexed separately because one cue name can be both (WallLeapBurst).
function CharacterFX.new(character: Model): CharacterFX
	local self = setmetatable({}, CharacterFX) :: any
	self._trove = Trove.new()
	self._sounds = {} :: { [string]: { Sound } }
	self._emitters = {} :: { [string]: { ParticleEmitter } }

	local function indexFor(instance: Instance): { [string]: { any } }?
		if not instance:GetAttribute(PresentationConstants.CueAttribute) then
			return nil
		end
		if instance:IsA("Sound") then
			return self._sounds
		elseif instance:IsA("ParticleEmitter") then
			return self._emitters
		end
		return nil
	end

	local function onAdded(instance: Instance)
		local index = indexFor(instance)
		if index then
			insert(index, instance)
		end
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		onAdded(descendant)
	end
	self._trove:Connect(character.DescendantAdded, onAdded)
	self._trove:Connect(character.DescendantRemoving, function(instance: Instance)
		local index = indexFor(instance)
		if index then
			remove(index, instance)
		end
	end)

	return self
end

-- Every mounted Sound with this name (both feet for a footstep); empty if
-- none is authored yet, so a missing effect is silent rather than an error.
function CharacterFX:GetSounds(name: string): { Sound }
	return self._sounds[name] or NONE
end

function CharacterFX:GetEmitters(name: string): { ParticleEmitter }
	return self._emitters[name] or NONE
end

function CharacterFX:Destroy()
	self._trove:Destroy()
end

-- A one-off lookup without a live index, for rare plays on characters this
-- client doesn't track per life (another player's Nearby cues).
function CharacterFX.Scan(character: Model, name: string): ({ Sound }, { ParticleEmitter })
	local sounds: { Sound } = {}
	local emitters: { ParticleEmitter } = {}
	for _, descendant in ipairs(character:GetDescendants()) do
		if
			descendant.Name == name
			and descendant:GetAttribute(PresentationConstants.CueAttribute)
		then
			if descendant:IsA("Sound") then
				table.insert(sounds, descendant)
			elseif descendant:IsA("ParticleEmitter") then
				table.insert(emitters, descendant)
			end
		end
	end
	return sounds, emitters
end

return CharacterFX
