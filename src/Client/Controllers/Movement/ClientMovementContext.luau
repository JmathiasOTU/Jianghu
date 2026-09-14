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
-- `slideSpeed` (docs/MOVEMENT.md §9) is Slide's own currently-decaying speed,
-- exposed the same way Run's dwell duration already is (`RunState.GetDuration()`
-- -> `context.runDuration`): a state exports its own internal timer/value via a
-- module function, `Movement/init.luau`'s `buildContext` reads it in, and any
-- OTHER state that needs it (SlideJumpState, for its boost) reads it off
-- `context` rather than requiring the sibling state module directly. Client-only
-- (not part of the shared MovementContext) -- the server never simulates
-- Slide's exact decay curve, it uses a flat SprintSpeed ceiling instead (see
-- `maxSpeedForState`), so it has no equivalent use for this value.
export type ClientMovementContext = MovementTypes.MovementContext & {
	characterMover: CharacterMover.CharacterMover,
	fsm: StateMachine.StateMachine<MovementState, MovementTypes.MovementContext>,
	slideSpeed: number?,
}

return {}
