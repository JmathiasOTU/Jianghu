--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)

export type CueDebounce = {
	TryFire: (self: CueDebounce, name: string) -> boolean,
}

local CueDebounce = {}
CueDebounce.__index = CueDebounce

-- Skips a one-shot cue replayed within MinCueRetriggerSeconds of its last
-- play, per cue name (docs/MOVEMENT_POLISH_ARCHITECTURE.md §1). Holds no
-- connections, so it needs no Trove. `clock` is injectable for tests.
function CueDebounce.new(clock: (() -> number)?): CueDebounce
	local self = setmetatable({}, CueDebounce) :: any
	self._clock = clock or os.clock
	self._lastFiredAt = {} :: { [string]: number }
	return self
end

-- Returns true and records the play if the cue may fire now.
function CueDebounce:TryFire(name: string): boolean
	local now = self._clock()
	local lastFiredAt = self._lastFiredAt[name]
	if lastFiredAt and now - lastFiredAt < PresentationConstants.MinCueRetriggerSeconds then
		return false
	end
	self._lastFiredAt[name] = now
	return true
end

return CueDebounce
