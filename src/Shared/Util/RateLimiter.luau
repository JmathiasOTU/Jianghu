--!strict

export type RateLimiter = {
	TryAcquire: (self: RateLimiter) -> boolean,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- table.remove(timestamps, 1) is an O(n) front-removal -- fine at the current
-- maxCalls (5, see every RateLimiter.new call site); revisit with an
-- index-based ring buffer only if a future caller needs a much higher maxCalls.
local function pruneExpired(self: any, now: number)
	local timestamps = self._timestamps
	while #timestamps > 0 and now - timestamps[1] > self._perSeconds do
		table.remove(timestamps, 1)
	end
end

-- Fixed-size sliding window: at most `maxCalls` acquisitions are allowed in any
-- trailing `perSeconds` window. Excess calls are rejected outright, never queued
-- -- for a security-relevant network gate, delaying and later executing an
-- exploiter's spam is worse than just dropping it. Holds no connections or
-- scheduled threads, so it needs no Trove/destroy: a per-player instance is just
-- dropped from whatever table holds it on cleanup.
function RateLimiter.new(maxCalls: number, perSeconds: number): RateLimiter
	assert(maxCalls > 0, "maxCalls must be > 0")
	assert(perSeconds > 0, "perSeconds must be > 0")

	local self = setmetatable({}, RateLimiter) :: any
	self._maxCalls = maxCalls
	self._perSeconds = perSeconds
	self._timestamps = {}
	return self
end

-- Returns true and records the call if under the limit; returns false (and
-- records nothing) if the caller is currently over the limit.
function RateLimiter:TryAcquire(): boolean
	local now = os.clock()
	pruneExpired(self, now)

	if #self._timestamps >= self._maxCalls then
		return false
	end

	table.insert(self._timestamps, now)
	return true
end

return RateLimiter
