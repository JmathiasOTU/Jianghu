--!strict

-- Minimal per-key violation counter/timestamp log (docs/MOVEMENT.md §5) -- not a
-- punishment system, just a record so a validation service has something to check
-- (and later act on) instead of silently correcting forever with no trace. Generic
-- on purpose: doesn't know anything about movement, players, or what "a violation"
-- means to its caller -- meant to be reused as-is by WallRun/ClimbVault/LedgeGrab/
-- Slide's validation services once Stage 2 starts building those.

export type Violation = {
	count: number,
	lastAt: number,
}

export type ViolationTracker = {
	Record: (self: ViolationTracker, key: any) -> Violation,
	Get: (self: ViolationTracker, key: any) -> Violation?,
	Clear: (self: ViolationTracker, key: any) -> (),
}

local ViolationTracker = {}
ViolationTracker.__index = ViolationTracker

function ViolationTracker.new(): ViolationTracker
	local self = setmetatable({}, ViolationTracker) :: any
	self._violations = {} :: { [any]: Violation }
	return self
end

-- Records one violation for `key` (any per-caller identity, e.g. a Player) and
-- returns the updated record. Not windowed/decayed like `RateLimiter` -- this is a
-- lifetime count for as long as the key is tracked, not a rate.
function ViolationTracker:Record(key: any): Violation
	local existing = self._violations[key]
	local violation: Violation = {
		count = if existing then existing.count + 1 else 1,
		lastAt = os.clock(),
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
