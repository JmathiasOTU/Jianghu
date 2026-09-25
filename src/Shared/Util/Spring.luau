--!strict

export type Spring<T> = {
	SetGoal: (self: Spring<T>, goal: T) -> (),
	SetFrequency: (self: Spring<T>, frequency: number) -> (),
	Update: (self: Spring<T>, dt: number) -> T,
	Reset: (self: Spring<T>, position: T) -> (),
}

local Spring = {}
Spring.__index = Spring

-- Exact step of x'' + 2*zeta*omega*x' + omega^2*x = 0, where x is the offset
-- from the goal: returns the matrix mapping (offset, velocity) now to
-- (offset, velocity) after `dt`. Closed form, so stepping is frame-rate
-- independent (docs/MOVEMENT_POLISH_ARCHITECTURE.md §4.1).
local function stepCoefficients(
	zeta: number,
	omega: number,
	dt: number
): (number, number, number, number)
	if zeta < 1 then
		local dampedOmega = omega * math.sqrt(1 - zeta * zeta)
		local decay = math.exp(-zeta * omega * dt)
		local cosine = math.cos(dampedOmega * dt)
		local sine = math.sin(dampedOmega * dt) / dampedOmega
		return decay * (cosine + zeta * omega * sine),
			decay * sine,
			-decay * omega * omega * sine,
			decay * (cosine - zeta * omega * sine)
	elseif zeta == 1 then
		local decay = math.exp(-omega * dt)
		return decay * (1 + omega * dt),
			decay * dt,
			-decay * omega * omega * dt,
			decay * (1 - omega * dt)
	end
	local root = omega * math.sqrt(zeta * zeta - 1)
	local fastRate = -zeta * omega - root
	local slowRate = -zeta * omega + root
	local slowDecay = math.exp(slowRate * dt)
	local fastDecay = math.exp(fastRate * dt)
	local span = fastRate - slowRate
	return (fastRate * slowDecay - slowRate * fastDecay) / span,
		(fastDecay - slowDecay) / span,
		slowRate * fastRate * (slowDecay - fastDecay) / span,
		(fastRate * fastDecay - slowRate * slowDecay) / span
end

-- Numbers and Vector3s share this implementation (both support +, - and
-- scaling by a number); the typed constructors below give callers a concrete
-- type, since a Luau generic can't be constrained to "supports arithmetic".
local function new(dampingRatio: number, frequency: number, initial: any, zero: any): any
	assert(dampingRatio >= 0, "dampingRatio must be >= 0")
	assert(frequency > 0, "frequency must be > 0")

	local self = setmetatable({}, Spring) :: any
	self._dampingRatio = dampingRatio
	self._angularFrequency = 2 * math.pi * frequency
	self._zero = zero
	self._position = initial
	self._velocity = zero
	self._goal = initial
	return self
end

-- `frequency` is the undamped frequency in Hz; `dampingRatio` 1 is critically
-- damped (fastest with no overshoot), below 1 overshoots, above 1 is sluggish.
function Spring.number(dampingRatio: number, frequency: number, initial: number): Spring<number>
	return new(dampingRatio, frequency, initial, 0)
end

function Spring.vector3(dampingRatio: number, frequency: number, initial: Vector3): Spring<Vector3>
	return new(dampingRatio, frequency, initial, Vector3.zero)
end

-- Keeps the current velocity, so a goal changed mid-blend curves toward the
-- new goal instead of restarting.
function Spring:SetGoal(goal: any)
	self._goal = goal
end

-- Takes effect from the next Update, keeping the current position and velocity.
function Spring:SetFrequency(frequency: number)
	assert(frequency > 0, "frequency must be > 0")
	self._angularFrequency = 2 * math.pi * frequency
end

function Spring:Update(dt: number): any
	local positionFromOffset, positionFromVelocity, velocityFromOffset, velocityFromVelocity =
		stepCoefficients(self._dampingRatio, self._angularFrequency, dt)
	local offset = self._position - self._goal
	local velocity = self._velocity
	self._position = self._goal + offset * positionFromOffset + velocity * positionFromVelocity
	self._velocity = offset * velocityFromOffset + velocity * velocityFromVelocity
	return self._position
end

-- Jumps straight to `position` and comes to rest there.
function Spring:Reset(position: any)
	self._position = position
	self._goal = position
	self._velocity = self._zero
end

return Spring
