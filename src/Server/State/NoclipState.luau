--!strict

-- Server-only shared state, same reasoning as MovementTuningState.luau
-- alongside it: DevToolsService.luau owns writing here (the only place
-- RequestSetNoclip is handled); MovementValidationService.luau only ever
-- reads, via IsActive, to exempt a noclipping session from
-- enforceSpeedSanity (docs/MOVEMENT.md §8) -- never trusting a
-- client-reported "I'm noclipping" flag for that exemption, only this
-- server-authorized record of who DevToolsService itself granted it to.
local NoclipState = {}

local active: { [Player]: boolean } = {}

function NoclipState.SetActive(player: Player, isActive: boolean)
	if isActive then
		active[player] = true
	else
		active[player] = nil
	end
end

function NoclipState.IsActive(player: Player): boolean
	return active[player] == true
end

-- Called on PlayerRemoving and on every CharacterAdded (a fresh character
-- never inherits noclip from the previous life -- DevToolsService.luau resets
-- CanCollide server-side to match).
function NoclipState.Clear(player: Player)
	active[player] = nil
end

return NoclipState
