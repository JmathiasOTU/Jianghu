--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local Trove = require(ReplicatedStorage.Packages.Trove)

export type StateMachine<State> = {
	current: State,
	changed: LemonSignal.Signal<State, State>,
	transition: (self: StateMachine<State>, next: State) -> boolean,
	canTransition: (self: StateMachine<State>, next: State) -> boolean,
	destroy: (self: StateMachine<State>) -> (),
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new<State>(
	initial: State,
	transitions: { [State]: { State } }
): StateMachine<State>
	local self = setmetatable({}, StateMachine) :: any
	self._trove = Trove.new()
	self.current = initial
	self.changed = self._trove:Add(LemonSignal.new(), "Destroy")
	self._transitions = transitions
	return self
end

function StateMachine:canTransition<State>(next: State): boolean
	local allowed = self._transitions[self.current]
	if not allowed then
		return false
	end
	for _, candidate in ipairs(allowed) do
		if candidate == next then
			return true
		end
	end
	return false
end

function StateMachine:transition<State>(next: State): boolean
	if not self:canTransition(next) then
		return false
	end
	local previous = self.current
	self.current = next
	self.changed:Fire(next, previous)
	return true
end

function StateMachine:destroy()
	self._trove:Destroy()
end

return StateMachine
