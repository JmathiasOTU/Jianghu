--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local CharacterMover = require(script.Parent.CharacterMover)

type MovementState = MovementStates.MovementState

-- Client-only superset of the Shared MovementContext (Shared/Types/MovementTypes):
-- adds the two things only client-side state Enter/Update/Exit bodies need
-- (CanEnter predicates, shared with the server, only ever see the plain
-- MovementContext). Lives in its own leaf module so init.luau and the State
-- modules can both depend on it without requiring each other.
export type ClientMovementContext = MovementTypes.MovementContext & {
	characterMover: CharacterMover.CharacterMover,
	fsm: StateMachine.StateMachine<MovementState, MovementTypes.MovementContext>,
}

return {}
