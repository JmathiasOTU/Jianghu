--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

-- Grounded-family states (docs/MovementSystem.md §4.4 rework) -- unified here during
-- the 2026-09-15 cleanup pass; previously hand-duplicated identically as
-- `GROUNDED_STATES` in both Client/Controllers/Movement/init.luau and
-- Server/Services/MovementValidationService.luau. Deliberately a plain set,
-- not derived from StateRules.Transitions -- "which states count as
-- grounded" and "which states can reach which" are different questions that
-- happen to share some membership. Landing into any of these is what resets
-- doubleJumpUsed/preAirborneLocomotion/peakHeight back to their grounded
-- baseline, mirrored 1:1 on both sides.
local Grounded: { [MovementState]: boolean } = {
	[MovementStates.Idle] = true,
	[MovementStates.Walk] = true,
	[MovementStates.Run] = true,
	[MovementStates.Sprint] = true,
	[MovementStates.CrouchIdle] = true,
	[MovementStates.CrouchWalk] = true,
	[MovementStates.HardLanding] = true,
}

return {
	Grounded = Grounded,
}
