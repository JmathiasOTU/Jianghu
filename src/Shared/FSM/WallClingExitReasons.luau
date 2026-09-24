--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Symbol = require(ReplicatedStorage.Packages.Symbol)

export type WallClingExitReason = typeof(Symbol())

-- WallCling exit reasons (docs/WallClimbingPlan.md §4) -- Symbols, never raw
-- strings (docs/ARCHITECTURE.md §2), so a typo fails to compile rather than
-- silently tagging a lockout with the wrong reason. Only Timeout/Dropped/
-- Boosted apply a lockout (see MovementConstants.WallCling{Timeout,Drop}Lockout
-- and WallClingPostBoostCooldown) -- WallLost/Interrupted apply none.
local WallClingExitReasons: { [string]: WallClingExitReason } = {
	Timeout = Symbol("WallClingExitTimeout"),
	Dropped = Symbol("WallClingExitDropped"),
	WallLost = Symbol("WallClingExitWallLost"),
	Interrupted = Symbol("WallClingExitInterrupted"),
	Boosted = Symbol("WallClingExitBoosted"),
}

return WallClingExitReasons
