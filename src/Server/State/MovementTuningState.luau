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

-- GetEffective is read several times per player per Heartbeat, so the merged
-- table is built once and reused until an override changes (audit M-021)
-- instead of allocating a fresh 46-field table on every call. Frozen, so no
-- caller can corrupt the copy everyone shares.
local shippedDefaults: EffectiveMovementConstants = table.freeze(MovementTuning.Defaults())
local effectiveCache: { [Player]: EffectiveMovementConstants } = {}

function MovementTuningState.SetOverride(player: Player, name: TunableConstantName, value: number)
	local playerOverrides = overrides[player]
	if not playerOverrides then
		playerOverrides = {}
		overrides[player] = playerOverrides
	end
	playerOverrides[name] = value
	effectiveCache[player] = nil
end

function MovementTuningState.ClearOverride(player: Player, name: TunableConstantName)
	local playerOverrides = overrides[player]
	if playerOverrides then
		playerOverrides[name] = nil
		effectiveCache[player] = nil
	end
end

function MovementTuningState.GetEffective(player: Player): EffectiveMovementConstants
	local playerOverrides = overrides[player]
	if not playerOverrides or next(playerOverrides) == nil then
		return shippedDefaults
	end
	local cached = effectiveCache[player]
	if not cached then
		cached = table.freeze(MovementTuning.WithOverrides(playerOverrides))
		effectiveCache[player] = cached
	end
	return cached
end

-- Called on PlayerRemoving so a departed player's overrides don't linger
-- forever in this table.
function MovementTuningState.Clear(player: Player)
	overrides[player] = nil
	effectiveCache[player] = nil
end

return MovementTuningState
