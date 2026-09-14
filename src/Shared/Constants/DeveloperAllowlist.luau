--!strict
local RunService = game:GetService("RunService")

-- Hardcoded developer UserIds for developer-only tools (e.g. the movement debug
-- overlay's teleport remote). Add real UserIds here as needed -- this is
-- deliberately a plain, checked-in table, not anything player- or
-- client-controlled.
local DEVELOPER_USER_IDS: { [number]: boolean } = {
	-- [123456789] = true,
}

local DeveloperAllowlist = {}

-- Shared between client and server so the two can never drift: the client uses
-- this to decide whether to even activate the debug overlay, the server uses the
-- exact same check as the actual security boundary for RequestDevTeleport (see
-- docs/MOVEMENT.md §5) -- client-side gating alone is never sufficient, but
-- reusing this one function means both sides agree on what "developer" means.
-- `RunService:IsStudio()` covers Studio/Team Test play without needing every
-- teammate's UserId added by hand; the allowlist covers verifying this on a real
-- published server.
function DeveloperAllowlist.IsDeveloper(player: Player): boolean
	return RunService:IsStudio() or DEVELOPER_USER_IDS[player.UserId] == true
end

return DeveloperAllowlist
