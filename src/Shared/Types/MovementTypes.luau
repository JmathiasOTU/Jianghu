--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)

-- `forward`/`backward`/`strafeLeft`/`strafeRight` are the raw WASD axis holds, kept
-- alongside the resolved `direction` because Sprint's continuation rule cares about
-- the raw forward key specifically (tolerates forward-diagonal, drops on backpedal
-- or pure strafe) -- see docs/MOVEMENT.md §2. `direction` is the camera-relative,
-- world-space vector actually driving movement.
export type MoveIntent = {
	direction: Vector3,
	forward: boolean,
	backward: boolean,
	strafeLeft: boolean,
	strafeRight: boolean,
}

-- `constants` is this session's EFFECTIVE movement tuning (live per-session
-- overrides merged over MovementConstants, or MovementConstants unmodified --
-- see Shared/Movement/MovementTuning.luau, docs/MOVEMENT.md §8). Added here,
-- not read directly off MovementConstants, so Shared/Movement/StateRules.luau's
-- CanEnter predicates (e.g. Sprint's dwell check) stay pure functions of
-- `context` alone -- both client and server build `constants` from the exact
-- same source (their own session's tuning state) before calling into
-- StateRules, so this can never itself become a client/server divergence.
export type MovementContext = {
	moveIntent: MoveIntent,
	grounded: boolean,
	runDuration: number?,
	constants: MovementTuning.EffectiveMovementConstants,
}

return {}
