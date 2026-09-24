--!strict

-- Minimal per-key violation counter/timestamp log (docs/MovementSystem.md §8) -- not a
-- punishment system, just a record so a validation service has something to check
-- (and later act on) instead of silently correcting forever with no trace. Generic
-- on purpose: doesn't know anything about movement, players, or what "a violation"
-- means to its caller -- meant to be reused as-is by WallRun/ClimbVault/LedgeGrab/
-- Slide's validation services once Stage 2 starts building those.

-- One individual violation's detail data -- generic on purpose, same as the
-- rest of this module: the caller decides what a "detail" means (for
-- MovementValidationService.enforceSpeedSanity, docs/MovementSystem.md §8/§10, it's
-- flatDelta/maxDistance/elapsed, the same numbers SPEED_SANITY_DEBUG_LOGGING
-- already printed).
export type ViolationDetail = { [string]: number }

export type ViolationEntry = ViolationDetail & { at: number }

export type Violation = {
	count: number,
	lastAt: number,
	history: { ViolationEntry },
}

-- Bounded per-key history length -- "a few recent entries," not a full
-- lifetime log (docs/MovementSystem.md §10): `count` above already covers the
-- lifetime total, this is only ever for a debug overlay's scrollback.
local HISTORY_LIMIT = 5

export type ViolationTracker = {
	Record: (self: ViolationTracker, key: any, detail: ViolationDetail?) -> Violation,
	Get: (self: ViolationTracker, key: any) -> Violation?,
	Clear: (self: ViolationTracker, key: any) -> (),
}

local ViolationTracker = {}
ViolationTracker.__index = ViolationTracker

-- Exported so a debug overlay sizes its row pool from this number (audit M-031).
ViolationTracker.HistoryLimit = HISTORY_LIMIT

function ViolationTracker.new(): ViolationTracker
	local self = setmetatable({}, ViolationTracker) :: any
	self._violations = {} :: { [any]: Violation }
	return self
end

-- Records one violation for `key` (any per-caller identity, e.g. a Player) and
-- returns the updated record. `count`/`lastAt` are not windowed/decayed like
-- `RateLimiter` -- a lifetime count for as long as the key is tracked, not a
-- rate. `detail` (if given) is pushed onto `history`, most-recent-first,
-- trimmed to HISTORY_LIMIT -- e.g. a debug overlay rendering the last few
-- corrections, not just the running count.
function ViolationTracker:Record(key: any, detail: ViolationDetail?): Violation
	local existing = self._violations[key]
	local history: { ViolationEntry } = if existing then existing.history else {}

	if detail then
		local entry: ViolationEntry = table.clone(detail) :: any
		entry.at = os.clock()
		table.insert(history, 1, entry)
		while #history > HISTORY_LIMIT do
			table.remove(history)
		end
	end

	local violation: Violation = {
		count = if existing then existing.count + 1 else 1,
		lastAt = os.clock(),
		history = history,
	}
	self._violations[key] = violation
	return violation
end

function ViolationTracker:Get(key: any): Violation?
	return self._violations[key]
end

-- Called on cleanup (e.g. `PlayerRemoving`) so the table doesn't grow unbounded
-- across reconnects/respawns.
function ViolationTracker:Clear(key: any)
	self._violations[key] = nil
end

return ViolationTracker
