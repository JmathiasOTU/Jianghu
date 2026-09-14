--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local RunState = {}

RunState.CanEnter = StateRules.CanEnter[MovementStates.Run]

-- Module-scope, not per-context: there is exactly one local-player FSM on the
-- client, so this is safe, and it's how RunState answers "how long have I been
-- continuously in Run" for both its own dwell check and the shared CanEnter
-- predicate for Sprint (via GetDuration below).
local enteredAt: number? = nil

function RunState.Enter(context: ClientMovementContext)
	enteredAt = os.clock()
	context.characterMover:SetSpeed(context.constants.RunSpeed)
end

-- "Continuously in Run for N seconds" reads as uninterrupted (docs/MOVEMENT.md §2):
-- losing the ground or losing input resets the dwell clock via Exit, it never
-- pauses and resumes. Crouch (docs/MOVEMENT.md §9) is checked before the
-- Sprint attempt -- pressing Ctrl while Running slides instead of continuing
-- to build toward Sprint, exactly the same priority-over-the-normal-family
-- reasoning as Idle/Walk's own crouch checks, just landing in Slide instead
-- of a Crouch variant since Run has no move-input ambiguity to resolve here.
function RunState.Update(_dt: number, context: ClientMovementContext)
	if not context.grounded then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	elseif context.crouchHeld then
		context.fsm:RequestTransition(MovementStates.Slide, context)
	elseif not StateRules.HasMoveInput(context) then
		context.fsm:RequestTransition(MovementStates.Idle, context)
	else
		context.fsm:RequestTransition(MovementStates.Sprint, context)
	end
end

function RunState.Exit(_context: ClientMovementContext)
	enteredAt = nil
end

-- Read by ClientMovementContext-building code (MovementController) each frame to
-- populate MovementContext.runDuration, and by Sprint's shared CanEnter predicate.
function RunState.GetDuration(): number?
	if not enteredAt then
		return nil
	end
	return os.clock() - enteredAt
end

return RunState
