--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)

-- Server-only pub/sub channel (docs/ARCHITECTURE.md §2: services never reach into
-- each other directly, they subscribe to shared state/events). Fired whenever a
-- player's character CFrame changes by something other than normal
-- Humanoid-driven movement -- today, only the debug overlay's developer teleport
-- tool. MovementValidationService subscribes to reset its speed-sanity baseline
-- instead of the teleport handler reaching into that service's session state
-- directly. A plain module-level singleton (import caching gives every requirer
-- the same instance), not owned by any one service's Trove -- it outlives every
-- individual player session for the life of the server.
local CharacterTeleported: LemonSignal.Signal<Player> = LemonSignal.new()

return CharacterTeleported
