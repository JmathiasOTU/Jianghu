--!strict

-- Published by Movement/init.luau every Heartbeat, read by DebugOverlayController
-- (F4 debug overlay, docs/MOVEMENT.md) -- a shared state module rather than the
-- overlay reaching into MovementController directly (docs/ARCHITECTURE.md §2:
-- "controllers never reach into each other directly, they subscribe to shared
-- state modules"). Poll-style, not signal-based: nothing needs to react to every
-- single frame's update, the overlay just samples Get() on its own render loop
-- while visible.
export type MovementDebugSnapshot = {
	state: string,
	grounded: boolean,
	runDuration: number?,
	speed: number,
}

local current: MovementDebugSnapshot = {
	state = "Idle",
	grounded = true,
	runDuration = nil,
	speed = 0,
}

local DebugSnapshot = {}

function DebugSnapshot.Set(snapshot: MovementDebugSnapshot)
	current = snapshot
end

function DebugSnapshot.Get(): MovementDebugSnapshot
	return current
end

return DebugSnapshot
