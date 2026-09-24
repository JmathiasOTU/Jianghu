--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local RateLimiter = require(ReplicatedStorage.Shared.Util.RateLimiter)

local Network = require(script.Parent.Parent.Network.network)
local MovementTuningState = require(script.Parent.Parent.State.MovementTuningState)
local DevToolsService = require(script.Parent.DevToolsService)

type TunableConstantName = MovementTuning.TunableConstantName
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants

-- Rate limit for RequestSetTuning, independent of the dev-only gate below
-- (docs/ARCHITECTURE.md §10) -- same reasoning as every other player-initiated
-- remote in this codebase.
local TUNING_CLAIMS_PER_SECOND = 5

local MovementTuningService = {}

local rateLimiters: { [Player]: RateLimiter.RateLimiter } = {}

-- Exposed for MovementValidationService's own buildContext to read (via
-- MovementTuningState.GetEffective directly, not through this service --
-- see that module for why). Kept here too since the overlay's "Tuning" tab
-- reset button and any other server-side caller conceptually wants "the
-- tuning service," not "the raw state table."
function MovementTuningService.GetEffective(player: Player): EffectiveMovementConstants
	return MovementTuningState.GetEffective(player)
end

local function broadcast(player: Player)
	Network.TuningState.Fire(
		player,
		MovementTuning.ToEntries(MovementTuningState.GetEffective(player))
	)
end

-- Dev-gated via DevToolsService.RegisterDevOnly (docs/MOVEMENT.md §8) -- the
-- second handler ever routed through it, after RequestDevTeleport's own
-- migration proved it works. `value == nil` clears the override; a real value
-- is bounds-checked (MovementTuning.IsValidValue) before being stored, same
-- "never trust a client-claimed number" rule as everywhere else
-- (docs/ARCHITECTURE.md §3) even though only a developer can reach this at
-- all -- a developer's client is still a client.
local onRequestSetTuning = DevToolsService.RegisterDevOnly(
	function(player: Player, request: { name: TunableConstantName, value: number? })
		local limiter = rateLimiters[player]
		if not limiter or not limiter:TryAcquire() then
			return
		end

		if request.value == nil then
			MovementTuningState.ClearOverride(player, request.name)
		else
			if not MovementTuning.IsValidValue(request.name, request.value) then
				return
			end
			MovementTuningState.SetOverride(player, request.name, request.value)
		end

		broadcast(player)
	end
)

-- Per-player connections, destroyed on PlayerRemoving (audit M-023).
local playerTroves: { [Player]: Trove.Trove } = {}

local function onPlayerAdded(player: Player)
	rateLimiters[player] = RateLimiter.new(TUNING_CLAIMS_PER_SECOND, 1)
	local playerTrove = Trove.new()
	playerTroves[player] = playerTrove

	playerTrove:Connect(player.CharacterAdded, function()
		-- Every new life gets the same effective numbers re-pushed so the
		-- client's TuningSnapshot never starts a life on stale defaults --
		-- overrides persist across respawns for the same player (a
		-- convenience while iterating on one value across several test
		-- jumps), only PlayerRemoving clears them.
		broadcast(player)
	end)
end

local function onPlayerRemoving(player: Player)
	rateLimiters[player] = nil
	MovementTuningState.Clear(player)
	local playerTrove = playerTroves[player]
	if playerTrove then
		playerTroves[player] = nil
		playerTrove:Destroy()
	end
end

function MovementTuningService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end

	Network.RequestSetTuning.SetCallback(onRequestSetTuning)
end

return MovementTuningService
