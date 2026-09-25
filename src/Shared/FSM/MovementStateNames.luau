--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

-- Symbol -> the plain string literal both the server's `MovementDebugState`
-- broadcast payload and the client's own `DebugSnapshot.RecordTransition`
-- need (Zap enums are string unions, not Symbols). Unified here during the
-- 2026-09-15 cleanup pass -- previously hand-duplicated identically as
-- `DEBUG_STATE_NAMES` in both Client/Controllers/Movement/init.luau and
-- Server/Services/MovementValidationService. A lookup table, not a
-- `tostring(Symbol)` call, so a typo here fails to compile rather than
-- silently sending "Unknown" forever -- same reasoning both original copies'
-- own comments already gave.
--
-- `DebugStateName` is a separate type alias from generated `network.zap`'s
-- `MovementStateName` -- this Shared module can't require either side's
-- generated `network.luau` (per-side build artifacts, docs/ARCHITECTURE.md
-- §10, and Client/Server each have their own copy at a different path) -- but
-- both expand to the identical literal-string union, so Luau's structural
-- typing accepts a `DebugStateName` value anywhere a `MovementStateName` is
-- expected. Keep this list in sync with network.zap's own `MovementStateName`
-- enum by hand; a drift would surface as a type error at the `Fire()` call
-- site, not silently.
export type DebugStateName =
	"Idle"
	| "Walk"
	| "Run"
	| "Sprint"
	| "Airborne"
	| "CrouchIdle"
	| "CrouchWalk"
	| "Slide"
	| "SlideJump"
	| "DoubleJump"
	| "HardLanding"
	| "WallRun"
	| "WallLeap"
	| "WallCling"
	| "WallBoost"

local DebugNames: { [MovementState]: DebugStateName } = {
	[MovementStates.Idle] = "Idle",
	[MovementStates.Walk] = "Walk",
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
	[MovementStates.Airborne] = "Airborne",
	[MovementStates.CrouchIdle] = "CrouchIdle",
	[MovementStates.CrouchWalk] = "CrouchWalk",
	[MovementStates.Slide] = "Slide",
	[MovementStates.SlideJump] = "SlideJump",
	[MovementStates.DoubleJump] = "DoubleJump",
	[MovementStates.HardLanding] = "HardLanding",
	[MovementStates.WallRun] = "WallRun",
	[MovementStates.WallLeap] = "WallLeap",
	[MovementStates.WallCling] = "WallCling",
	[MovementStates.WallBoost] = "WallBoost",
}

return {
	DebugNames = DebugNames,
}
