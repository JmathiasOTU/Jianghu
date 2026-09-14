--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)

-- Rate limit for RequestDevTeleport, independent of the authorization check below
-- (docs/ARCHITECTURE.md §10) -- a network-layer concern, not gameplay tuning, so
-- it's a local constant here rather than in MovementConstants, same reasoning as
-- MovementValidationService's own TRANSITION_CLAIMS_PER_SECOND.
local TELEPORT_CLAIMS_PER_SECOND = 3

local DevToolsService = {}

local rateLimiters: { [Player]: RateLimiter.RateLimiter } = {}

local function onPlayerAdded(player: Player)
	rateLimiters[player] = RateLimiter.new(TELEPORT_CLAIMS_PER_SECOND, 1)
end

local function onPlayerRemoving(player: Player)
	rateLimiters[player] = nil
end

-- Developer-only (docs/MOVEMENT.md, debug overlay). `DeveloperAllowlist.IsDeveloper`
-- is checked FIRST, before anything else in this handler runs -- client-side UI
-- visibility is never the security boundary here, this is. It's the exact same
-- check the client uses to decide whether to even show the overlay, so there's one
-- source of truth for "who counts as a developer," not two definitions that could
-- drift apart.
local function onRequestDevTeleport(player: Player, position: vector)
	if not DeveloperAllowlist.IsDeveloper(player) then
		return
	end

	local limiter = rateLimiters[player]
	if not limiter or not limiter:tryAcquire() then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end

	local destination = Vector3.new(position.x, position.y, position.z)
	rootPart.CFrame = (rootPart.CFrame - rootPart.Position) + destination
	rootPart.AssemblyLinearVelocity = Vector3.zero

	-- MovementValidationService's speed/delta-position sanity check has no way to
	-- distinguish this from a speed hack on its own -- without this, it would
	-- measure the teleport as an impossible jump and snap the player straight back
	-- on the very next sample, silently undoing the teleport. See
	-- docs/ARCHITECTURE.md §2 on why this is a published event rather than
	-- DevToolsService reaching into that service's session state directly.
	CharacterTeleported:Fire(player)
end

function DevToolsService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Network.RequestDevTeleport.SetCallback(onRequestDevTeleport)
end

return DevToolsService
