--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local Network = require(script.Parent.Parent.Network.network)
local CharacterTeleported = require(script.Parent.Parent.Events.CharacterTeleported)
local NoclipState = require(script.Parent.Parent.State.NoclipState)
local DebugOverlayState = require(script.Parent.Parent.State.DebugOverlayState)

-- Rate limits for the dev-only remotes below, independent of the authorization
-- check (docs/ARCHITECTURE.md §10) -- a network-layer concern, not gameplay
-- tuning, so these are local constants here rather than in MovementConstants,
-- same reasoning as MovementValidationService's own TRANSITION_CLAIMS_PER_SECOND.
local TELEPORT_CLAIMS_PER_SECOND = 3
local NOCLIP_CLAIMS_PER_SECOND = 2
-- Open/close is a rare, deliberate user action (F4 press or a button click),
-- not a per-frame stream -- this ceiling only exists so the remote isn't
-- exempt from the "every player-initiated remote gets a rate limit" rule
-- (docs/ARCHITECTURE.md §10), same as every other dev-only remote here.
local DEBUG_OVERLAY_OPEN_CLAIMS_PER_SECOND = 5

local DevToolsService = {}

local teleportRateLimiters: { [Player]: RateLimiter.RateLimiter } = {}
local noclipRateLimiters: { [Player]: RateLimiter.RateLimiter } = {}
local debugOverlayOpenRateLimiters: { [Player]: RateLimiter.RateLimiter } = {}
-- Per-player connections, destroyed on PlayerRemoving (audit M-023).
local playerTroves: { [Player]: Trove.Trove } = {}
-- Each part's own CanCollide from before noclip turned it off, so turning
-- noclip back off restores it instead of forcing every part (accessory
-- handles included) to collide (audit M-029). Weak-keyed on the part.
local canCollideBeforeNoclip: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function isFiniteVector(position: vector): boolean
	for _, component in ipairs({ position.x, position.y, position.z }) do
		if component ~= component or component == math.huge or component == -math.huge then
			return false
		end
	end
	return true
end

-- The one, single-source-of-truth developer gate every dev-only remote in this
-- codebase routes through (docs/MOVEMENT.md §8) -- extracted 2026-09-14 BEFORE
-- any remote past RequestDevTeleport was added, specifically so the
-- `DeveloperAllowlist.IsDeveloper` check can never be forgotten on a later
-- remote (live tuning, noclip, ...): it's now structurally impossible to reach
-- `handler` without it, rather than a copy-pasted `if not ... then return end`
-- at the top of each new handler that a future edit could accidentally drop.
-- Wraps any (Player, ...) callback shape, so it fits SetCallback's signature
-- for every remote regardless of payload.
function DevToolsService.RegisterDevOnly<Args...>(
	handler: (player: Player, Args...) -> ()
): (player: Player, Args...) -> ()
	return function(player: Player, ...: Args...)
		if not DeveloperAllowlist.IsDeveloper(player) then
			return
		end
		handler(player, ...)
	end
end

-- Migrated onto RegisterDevOnly first (docs/MOVEMENT.md §8), as the proof it
-- behaves identically to the inline check it replaces, before any other
-- handler adopts it.
local onRequestDevTeleport = DevToolsService.RegisterDevOnly(
	function(player: Player, position: vector)
		local limiter = teleportRateLimiters[player]
		if not limiter or not limiter:TryAcquire() then
			return
		end
		-- Zap's f32 write_checks don't reject NaN/inf (audit M-029), and a
		-- NaN CFrame corrupts the character's physics.
		if not isFiniteVector(position) then
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
)

-- Noclip/fly scouting tool (docs/MOVEMENT.md §8). Collision is disabled here,
-- server-side, on every BasePart of the character -- the actual fly movement
-- is driven client-side (Client/Controllers/Movement/NoclipController.luau)
-- since the player's own character is already network-owned by that client for
-- ordinary movement, same as how a legitimate client already drives its own
-- WalkSpeed-based motion. `NoclipState` (Server/State/NoclipState.luau) is the
-- server-authorized record MovementValidationService.enforceSpeedSanity
-- exempts against -- never anything the client asserts about itself.
local onRequestSetNoclip = DevToolsService.RegisterDevOnly(
	function(player: Player, enabled: boolean)
		local limiter = noclipRateLimiters[player]
		if not limiter or not limiter:TryAcquire() then
			return
		end

		local character = player.Character
		if not character then
			return
		end

		NoclipState.SetActive(player, enabled)
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				if enabled then
					if canCollideBeforeNoclip[descendant] == nil then
						canCollideBeforeNoclip[descendant] = descendant.CanCollide
					end
					descendant.CanCollide = false
				else
					local original = canCollideBeforeNoclip[descendant]
					if original ~= nil then
						descendant.CanCollide = original
						canCollideBeforeNoclip[descendant] = nil
					end
				end
			end
		end

		if not enabled then
			-- Same "reset the baseline, don't pad the tolerance" fix as the
			-- teleport handler above: while noclipping, enforceSpeedSanity skips
			-- this session entirely and its speed-check baseline goes stale, so
			-- the moment collision/gravity resume, this avoids comparing the
			-- discontinuous re-entry position against wherever the player was
			-- flying long before.
			CharacterTeleported:Fire(player)
		end

		Network.NoclipState.Fire(player, enabled)
	end
)

-- F4 overlay open/close (docs/MOVEMENT.md §10, `TRAVERSAL-ROADMAP.md` Phase
-- 0 cleanup). `DebugOverlayState` is what `MovementValidationService.
-- broadcastDebugState` gates its per-Heartbeat broadcast on -- without this,
-- that broadcast runs unconditionally for every connected developer
-- regardless of whether their panel is even visible.
local onRequestSetDebugOverlayOpen = DevToolsService.RegisterDevOnly(
	function(player: Player, isOpen: boolean)
		local limiter = debugOverlayOpenRateLimiters[player]
		if not limiter or not limiter:TryAcquire() then
			return
		end

		DebugOverlayState.SetOpen(player, isOpen)
	end
)

local function onPlayerAdded(player: Player)
	teleportRateLimiters[player] = RateLimiter.new(TELEPORT_CLAIMS_PER_SECOND, 1)
	noclipRateLimiters[player] = RateLimiter.new(NOCLIP_CLAIMS_PER_SECOND, 1)
	debugOverlayOpenRateLimiters[player] = RateLimiter.new(DEBUG_OVERLAY_OPEN_CLAIMS_PER_SECOND, 1)
	local playerTrove = Trove.new()
	playerTroves[player] = playerTrove

	playerTrove:Connect(player.CharacterAdded, function()
		-- A fresh character never inherits noclip from the previous life --
		-- its BaseParts start at their normal CanCollide values already, this
		-- just keeps the server-authorized record in sync with that.
		NoclipState.Clear(player)
	end)
end

local function onPlayerRemoving(player: Player)
	teleportRateLimiters[player] = nil
	noclipRateLimiters[player] = nil
	debugOverlayOpenRateLimiters[player] = nil
	NoclipState.Clear(player)
	DebugOverlayState.Clear(player)
	local playerTrove = playerTroves[player]
	if playerTrove then
		playerTroves[player] = nil
		playerTrove:Destroy()
	end
end

function DevToolsService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Network.RequestDevTeleport.SetCallback(onRequestDevTeleport)
	Network.RequestSetNoclip.SetCallback(onRequestSetNoclip)
	Network.RequestSetDebugOverlayOpen.SetCallback(onRequestSetDebugOverlayOpen)
end

return DevToolsService
