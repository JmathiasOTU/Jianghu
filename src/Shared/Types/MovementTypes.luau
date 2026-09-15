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
-- `jumping` (docs/MOVEMENT.md §9, Crouch/Slide slice) is the Humanoid's own
-- `Jumping` state, read the same way `grounded` already is -- both sides
-- derive it from the same already-replicated `Humanoid:GetState()`, so it's a
-- shared context field rather than something only one side computes.
-- SlideJump's entry gate reads this (jump pressed while sliding), never a
-- claim -- exactly like Airborne's own entry, no discrete gesture to earn.
--
-- `crouchHeld` is the one signal in this whole system that ISN'T derivable
-- from anything Roblox already replicates (unlike `moveIntent`/`grounded`/
-- `jumping`, all read off `Humanoid`) -- the server only has it because the
-- client explicitly tells it (`RequestMovementTransition`'s "CrouchDown"/
-- "CrouchUp" claims, docs/MOVEMENT.md §9), stored per-session
-- (`PlayerSession.crouchHeld`) rather than derived fresh each frame the way
-- everything else in this type is.
-- `doubleJumpUsed` (TRAVERSAL-ROADMAP.md §4, Phase 1) is the one other signal
-- in this type that isn't derivable fresh from Humanoid replication each
-- frame -- like `crouchHeld`, it has to be tracked as per-life state by
-- whoever owns the FSM lifecycle (`Movement/init.luau` client-side,
-- `PlayerSession` server-side), reset the instant the character lands and
-- set once DoubleJump is entered, never recomputed from a physics read.
export type MovementContext = {
	moveIntent: MoveIntent,
	grounded: boolean,
	jumping: boolean,
	crouchHeld: boolean,
	doubleJumpUsed: boolean,
	runDuration: number?,
	constants: MovementTuning.EffectiveMovementConstants,
}

return {}
