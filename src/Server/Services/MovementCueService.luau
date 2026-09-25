--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local MovementCues = require(ReplicatedStorage.Shared.Presentation.MovementCues)
local CueDebounce = require(ReplicatedStorage.Shared.Presentation.CueDebounce)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)

local Network = require(script.Parent.Parent.Network.network)
local MirrorStateChanged = require(script.Parent.Parent.Events.MirrorStateChanged)

type MovementState = MovementStates.MovementState

-- Movement FX on the server side (docs/MOVEMENT_POLISH_ARCHITECTURE.md §2,
-- §5): mounts the FX rig template onto every character, and tells every other
-- client when a player enters a state whose cue is "Nearby". Cosmetic only;
-- never touches movement state.
local MovementCueService = {}

-- Mirrors the R6 rig: <part name>/<attachment name>/<effects>.
local TEMPLATE =
	ReplicatedStorage:WaitForChild("Assets"):WaitForChild("FX"):WaitForChild("Movement")

-- Sounds bystanders hear, which need a tight roll-off: Roblox's default
-- RollOffMaxDistance reaches across the whole map.
local NEARBY_SOUNDS: { [string]: boolean } = {}
for _, cue in pairs(MovementCues) do
	if cue.Replication == "Nearby" and cue.EnterSound then
		NEARBY_SOUNDS[cue.EnterSound] = true
	end
end

-- Per-player connections, destroyed on PlayerRemoving.
local playerTroves: { [Player]: Trove.Trove } = {}
-- Per-player Nearby broadcast floor, matching the clients' own debounce.
local broadcastDebounces: { [Player]: CueDebounce.CueDebounce } = {}

local function prepare(effect: Instance, packSoundGroup: unknown)
	effect:SetAttribute(PresentationConstants.CueAttribute, true)
	if effect:IsA("Sound") then
		local groupName = effect:GetAttribute(PresentationConstants.SoundGroupAttribute)
			or packSoundGroup
		if typeof(groupName) == "string" then
			local group = SoundService:FindFirstChild(groupName)
			if group and group:IsA("SoundGroup") then
				effect.SoundGroup = group
			else
				warn(
					string.format(
						"[MovementCueService] %s names SoundGroup %q, which isn't in SoundService",
						effect.Name,
						groupName
					)
				)
			end
		end
		if NEARBY_SOUNDS[effect.Name] then
			effect.RollOffMode = Enum.RollOffMode.InverseTapered
			effect.RollOffMaxDistance = PresentationConstants.NearbyRollOffMaxDistance
		end
	elseif effect:IsA("ParticleEmitter") then
		-- Loops start when their state does, whatever the template was saved with.
		effect.Enabled = false
	end
end

local function mountEffect(
	effect: Instance,
	name: string,
	attachment: Attachment,
	packSoundGroup: unknown
)
	local clone = effect:Clone()
	clone.Name = name
	prepare(clone, packSoundGroup)
	clone.Parent = attachment
end

local function isEffect(instance: Instance): boolean
	return instance:IsA("Sound") or instance:IsA("ParticleEmitter")
end

-- Any other container under an attachment folder (a Folder, or the SoundGroup
-- a toolbox pack ships in) is a pack, e.g. per-material footsteps saved from
-- Studio as one file: each effect in it mounts flat on the attachment as
-- <pack name><effect name> ("Footstep" + "Concrete"), since a Sound only
-- plays positionally directly under a part or attachment. Its sounds inherit
-- the pack's SoundGroup attribute unless they set their own.
local function mountChild(child: Instance, attachment: Attachment)
	if isEffect(child) then
		mountEffect(child, child.Name, attachment, nil)
		return
	end
	local packSoundGroup = child:GetAttribute(PresentationConstants.SoundGroupAttribute)
	for _, effect in ipairs(child:GetDescendants()) do
		if isEffect(effect) then
			mountEffect(effect, child.Name .. effect.Name, attachment, packSoundGroup)
		end
	end
end

local function mount(character: Model)
	if character:GetAttribute(PresentationConstants.MountedAttribute) then
		return
	end
	character:SetAttribute(PresentationConstants.MountedAttribute, true)

	for _, partFolder in ipairs(TEMPLATE:GetChildren()) do
		local part = character:FindFirstChild(partFolder.Name)
		for _, attachmentFolder in ipairs(partFolder:GetChildren()) do
			local attachment = part and part:FindFirstChild(attachmentFolder.Name)
			if not (attachment and attachment:IsA("Attachment")) then
				warn(
					string.format(
						"[MovementCueService] %s has no %s.%s to mount FX on",
						character:GetFullName(),
						partFolder.Name,
						attachmentFolder.Name
					)
				)
				continue
			end
			for _, child in ipairs(attachmentFolder:GetChildren()) do
				mountChild(child, attachment)
			end
		end
	end
end

-- Driven by the server's own mirror, so bystanders only ever see moves the
-- server accepted, and there's no client request to trust or rate-limit. The
-- mover is excluded: their client already played the cue locally.
local function onMirrorStateChanged(player: Player, next: MovementState)
	local cue = MovementCues[next]
	if not (cue and cue.Replication == "Nearby") then
		return
	end
	local stateName = MovementStateNames.DebugNames[next]
	local debounce = broadcastDebounces[player]
	if not (stateName and debounce and debounce:TryFire(stateName)) then
		return
	end
	Network.PlayMovementCue.FireExcept(player, { player = player, state = stateName })
end

local function onPlayerAdded(player: Player)
	local trove = Trove.new()
	playerTroves[player] = trove
	broadcastDebounces[player] = CueDebounce.new()
	trove:Connect(player.CharacterAdded, mount)
	if player.Character then
		mount(player.Character)
	end
end

function MovementCueService.Init()
	MirrorStateChanged:Connect(onMirrorStateChanged)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		local trove = playerTroves[player]
		if trove then
			trove:Destroy()
			playerTroves[player] = nil
		end
		broadcastDebounces[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
end

return MovementCueService
