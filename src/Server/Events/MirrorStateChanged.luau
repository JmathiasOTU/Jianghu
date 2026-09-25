--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

-- Server-only pub/sub channel (docs/ARCHITECTURE.md §2): fired by
-- MovementValidationService every time a player's mirrored movement FSM
-- changes state, after its own bookkeeping for that change. Lets services
-- react to server-accepted movement without reaching into the validation
-- service; today MovementCueService uses it to broadcast Nearby cues
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §5).
--
-- Arguments: the player, the state entered, the state left. SlideJump and
-- WallLeap hand off to Airborne inside their own transition, so a listener
-- can see those two changes out of order; react to `next`, not to a
-- running "current state" built from these.
local MirrorStateChanged: LemonSignal.Signal<Player, MovementState, MovementState> =
	LemonSignal.new()

return MirrorStateChanged
