--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)

-- Server-only pub/sub channel (docs/ARCHITECTURE.md §2/§5, audit M-008,
-- designer decision 2026-09-24): fired once for every movement correction
-- MovementValidationService makes, AFTER it has already snapped the player
-- back. Nothing subscribes yet -- this is the hook a future moderation
-- system (flagging, logging to a store, kicks) listens on, so that policy
-- never has to live inside the validation service.
--
-- Arguments: the player, the violation kind ("Speed", "VerticalCeiling",
-- "HardLandingEscape"), that correction's detail numbers, and how many
-- violations of that kind the player has had this session.
export type Kind = "Speed" | "VerticalCeiling" | "HardLandingEscape"

local MovementViolation: LemonSignal.Signal<Player, Kind, { [string]: number }, number> =
	LemonSignal.new()

return MovementViolation
