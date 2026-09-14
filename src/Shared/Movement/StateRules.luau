--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

local function hasMoveInput(context: MovementContext): boolean
	return context.moveIntent.direction.Magnitude > 0
end

-- Topology: which states can graph-wise reach which. Purely "is this edge legal",
-- not "is it legal right now" -- that's CanEnter below. Shared client/server so both
-- FSM mirrors are built from the identical graph.
local Transitions: { [MovementState]: { MovementState } } = {
	[MovementStates.Idle] = { MovementStates.Walk, MovementStates.Run, MovementStates.Airborne },
	[MovementStates.Walk] = { MovementStates.Idle, MovementStates.Run, MovementStates.Airborne },
	[MovementStates.Run] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Sprint,
		MovementStates.Airborne,
	},
	[MovementStates.Sprint] = { MovementStates.Idle, MovementStates.Run, MovementStates.Airborne },
	[MovementStates.Airborne] = { MovementStates.Idle, MovementStates.Walk, MovementStates.Run },
}

-- CanEnter: is this transition legal RIGHT NOW, given live context. Shared
-- client/server per docs/MOVEMENT.md §1 so a hacked client can't diverge from what
-- the server will accept.
local CanEnter: { [MovementState]: (context: MovementContext) -> boolean } = {
	[MovementStates.Idle] = function(context: MovementContext): boolean
		return context.grounded
	end,

	[MovementStates.Walk] = function(context: MovementContext): boolean
		return context.grounded and hasMoveInput(context)
	end,

	[MovementStates.Run] = function(context: MovementContext): boolean
		return context.grounded and hasMoveInput(context)
	end,

	[MovementStates.Sprint] = function(context: MovementContext): boolean
		local threshold = context.constants.SprintThresholdSeconds
		return context.grounded and context.runDuration ~= nil and (context.runDuration :: number) >= threshold
	end,

	[MovementStates.Airborne] = function(context: MovementContext): boolean
		return not context.grounded
	end,
}

local StateRules = {
	Transitions = Transitions,
	CanEnter = CanEnter,
	HasMoveInput = hasMoveInput,
}

return StateRules
