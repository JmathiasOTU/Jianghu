--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)

type TunableConstantName = MovementTuning.TunableConstantName
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants

-- Server-only shared state (Server/Events/CharacterTeleported.luau's pattern:
-- a plain module in a non-`Services/` folder so two services can share data
-- WITHOUT reaching into each other's internals directly, per
-- docs/ARCHITECTURE.md §2). MovementTuningService.luau owns writing here (the
-- only place RequestSetTuning is handled); MovementValidationService.luau only
-- ever reads, via GetEffective, to build each session's context.constants
-- (docs/MOVEMENT.md §5/§8).
--
-- Per-player, never global: an override here can only ever affect the
-- overriding developer's own session, exactly like the tuning feature's own
-- design requirement -- there is no key that means "everyone."
local MovementTuningState = {}

local overrides: { [Player]: { [TunableConstantName]: number } } = {}

function MovementTuningState.SetOverride(player: Player, name: TunableConstantName, value: number)
	local playerOverrides = overrides[player]
	if not playerOverrides then
		playerOverrides = {}
		overrides[player] = playerOverrides
	end
	playerOverrides[name] = value
end

function MovementTuningState.ClearOverride(player: Player, name: TunableConstantName)
	local playerOverrides = overrides[player]
	if playerOverrides then
		playerOverrides[name] = nil
	end
end

function MovementTuningState.GetEffective(player: Player): EffectiveMovementConstants
	return MovementTuning.WithOverrides(overrides[player])
end

-- Called on PlayerRemoving so a departed player's overrides don't linger
-- forever in this table.
function MovementTuningState.Clear(player: Player)
	overrides[player] = nil
end

return MovementTuningState
