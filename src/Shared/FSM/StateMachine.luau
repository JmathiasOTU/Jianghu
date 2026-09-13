--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local Trove = require(ReplicatedStorage.Packages.Trove)

export type StateMachine<State, Context> = {
	current: State,
	changed: LemonSignal.Signal<State, State>,
	requestTransition: (self: StateMachine<State, Context>, next: State, context: Context) -> boolean,
	canTransition: (self: StateMachine<State, Context>, next: State, context: Context) -> boolean,
	destroy: (self: StateMachine<State, Context>) -> (),
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new<State, Context>(
	initial: State,
	transitions: { [State]: { State } },
	rules: { [State]: (context: Context) -> boolean }?
): StateMachine<State, Context>
	local self = setmetatable({}, StateMachine) :: any
	self._trove = Trove.new()
	self.current = initial
	self.changed = self._trove:Add(LemonSignal.new(), "Destroy")
	self._transitions = transitions
	self._rules = rules
	return self
end

function StateMachine:canTransition<State, Context>(next: State, context: Context): boolean
	local allowed = self._transitions[self.current]
	if not allowed then
		return false
	end
	local reachable = false
	for _, candidate in ipairs(allowed) do
		if candidate == next then
			reachable = true
			break
		end
	end
	if not reachable then
		return false
	end
	local rule = self._rules and self._rules[next]
	if rule and not rule(context) then
		return false
	end
	return true
end

function StateMachine:requestTransition<State, Context>(next: State, context: Context): boolean
	if not self:canTransition(next, context) then
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
