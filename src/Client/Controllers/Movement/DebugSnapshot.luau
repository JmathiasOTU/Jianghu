--!strict

-- Published by Movement/init.luau every Heartbeat, read by DebugOverlayController
-- (F4 debug overlay, docs/MOVEMENT.md) -- a shared state module rather than the
-- overlay reaching into MovementController directly (docs/ARCHITECTURE.md §2:
-- "controllers never reach into each other directly, they subscribe to shared
-- state modules"). Poll-style, not signal-based: nothing needs to react to every
-- single frame's update, the overlay just samples Get() on its own render loop
-- while visible.
--
-- `velocity`/`rotVelocity` (added docs/MOVEMENT.md §8) are the character
-- rootPart's real `AssemblyLinearVelocity`/`AssemblyAngularVelocity` -- `speed`
-- is kept alongside them unchanged (flattened horizontal magnitude, what the
-- overlay showed before this pass) rather than replaced, since it's still the
-- quickest single number to eyeball against a state's speed tier.
-- `noclip` (added alongside velocity/rotVelocity, docs/MOVEMENT.md §8) is the
-- server-confirmed noclip state for this life, mirrored here for the same
-- reason `speed`/`state` are -- so the overlay's World tab can render the
-- toggle's current state by polling this module instead of reaching into
-- Movement/init.luau's NoclipController directly.
export type MovementDebugSnapshot = {
	state: string,
	grounded: boolean,
	runDuration: number?,
	speed: number,
	velocity: Vector3,
	rotVelocity: Vector3,
	noclip: boolean,
}

local current: MovementDebugSnapshot = {
	state = "Idle",
	grounded = true,
	runDuration = nil,
	speed = 0,
	velocity = Vector3.zero,
	rotVelocity = Vector3.zero,
	noclip = false,
}

-- State-transition history (docs/MOVEMENT.md §8): a bounded ring buffer of the
-- client FSM's last few `fsm.changed` firings, populated by Movement/init.luau
-- off its existing connection -- not a new one -- most-recent-first so the
-- overlay can render it directly without re-sorting.
export type StateTransition = {
	state: string,
	at: number,
}

local STATE_HISTORY_LIMIT = 10
local stateHistory: { StateTransition } = {}

-- Network claim log (docs/MOVEMENT.md §8): the client's own
-- RequestMovementTransition sends (Run/Sprint claims), same bounded/
-- most-recent-first ring buffer shape as state history above. `reflected` is
-- left unset here on purpose -- DebugOverlayController mutates it in place
-- once it can tell, from the existing MovementDebugState broadcast, whether
-- the server ever mirrored the claim (nil = still pending, true = confirmed,
-- false = timed out unconfirmed). This module only ever appends entries; it
-- doesn't know anything about the server broadcast that resolves them.
export type ClaimLogEntry = {
	state: "Run" | "Sprint",
	at: number,
	reflected: boolean?,
}

local CLAIM_LOG_LIMIT = 8
local claimLog: { ClaimLogEntry } = {}

local DebugSnapshot = {}

function DebugSnapshot.Set(snapshot: MovementDebugSnapshot)
	current = snapshot
end

function DebugSnapshot.Get(): MovementDebugSnapshot
	return current
end

function DebugSnapshot.RecordTransition(state: string)
	table.insert(stateHistory, 1, { state = state, at = os.clock() })
	while #stateHistory > STATE_HISTORY_LIMIT do
		table.remove(stateHistory)
	end
end

function DebugSnapshot.GetStateHistory(): { StateTransition }
	return stateHistory
end

function DebugSnapshot.RecordClaim(state: "Run" | "Sprint")
	table.insert(claimLog, 1, { state = state, at = os.clock(), reflected = nil })
	while #claimLog > CLAIM_LOG_LIMIT do
		table.remove(claimLog)
	end
end

-- Returned by reference, deliberately -- DebugOverlayController marks entries
-- `reflected` in place as it reconciles them against server broadcasts (see
-- ClaimLogEntry above).
function DebugSnapshot.GetClaimLog(): { ClaimLogEntry }
	return claimLog
end

return DebugSnapshot
