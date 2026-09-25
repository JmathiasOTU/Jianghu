--!strict

-- Server-only shared state, same reasoning as NoclipState.luau alongside it:
-- DevToolsService.luau owns writing here (the only place
-- RequestSetDebugOverlayOpen is handled); MovementValidationService only
-- ever reads, via IsOpen, to gate DebugBroadcast.Send (docs/MovementSystem.md §10) --
-- never trusting a client-reported "my panel is open" flag for anything more
-- than "should I bother sending this session network traffic," which is the
-- only thing this record is used for; nothing security-relevant reads it.
local DebugOverlayState = {}

local open: { [Player]: boolean } = {}

function DebugOverlayState.SetOpen(player: Player, isOpen: boolean)
	if isOpen then
		open[player] = true
	else
		open[player] = nil
	end
end

function DebugOverlayState.IsOpen(player: Player): boolean
	return open[player] == true
end

-- Called on PlayerRemoving so a departed player's entry doesn't linger
-- forever in this table.
function DebugOverlayState.Clear(player: Player)
	open[player] = nil
end

return DebugOverlayState
