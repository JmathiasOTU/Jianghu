--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)

type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants

-- Client-side mirror of Server/State/MovementTuningState.luau's per-session
-- effective constants (docs/MOVEMENT.md §8), same poll-style published-state
-- pattern as DebugSnapshot.luau alongside it: Movement/init.luau writes here
-- (via Set, fed by the TuningState network callback), every consumer that
-- needs a live-tunable number -- the state modules, CharacterMover,
-- InputController's double-tap window, DebugOverlayController's Tuning tab --
-- polls Get() rather than reaching into MovementController or the network
-- callback directly (docs/ARCHITECTURE.md §2).
--
-- Starts on MovementTuning.Defaults() (the shipped MovementConstants values,
-- no override) so nothing here is ever nil before the server's first
-- broadcast arrives -- same reasoning as DebugSnapshot's initial `current`.
local current: EffectiveMovementConstants = MovementTuning.Defaults()

local TuningSnapshot = {}

function TuningSnapshot.Set(constants: EffectiveMovementConstants)
	current = constants
end

function TuningSnapshot.Get(): EffectiveMovementConstants
	return current
end

return TuningSnapshot
