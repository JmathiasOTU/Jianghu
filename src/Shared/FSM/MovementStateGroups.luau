--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

-- Grounded-family states (docs/MovementSystem.md §4.4 rework) -- unified here during
-- the 2026-09-15 cleanup pass; previously hand-duplicated identically as
-- `GROUNDED_STATES` in both Client/Controllers/Movement/init.luau and
-- Server/Services/MovementValidationService. Deliberately a plain set,
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

-- Entering any of these adds Flow on both sides (docs/FLOW.md §0). WallCling
-- is a hold, not a move (the boost from it counts); Run/Sprint never build it.
local FlowBuilding: { [MovementState]: boolean } = {
	[MovementStates.SlideJump] = true,
	[MovementStates.WallRun] = true,
	[MovementStates.WallLeap] = true,
	[MovementStates.WallBoost] = true,
	[MovementStates.Vault] = true,
	[MovementStates.DoubleJump] = true,
}

-- Entering any of these raises the server's held Flow multiplier (docs/FLOW.md
-- §4): the client's horizontal speed there is fixed at launch or slide entry
-- and doesn't follow Flow down as it drains.
local FlowHolding: { [MovementState]: boolean } = {
	[MovementStates.Slide] = true,
	[MovementStates.SlideJump] = true,
	[MovementStates.Airborne] = true,
	[MovementStates.DoubleJump] = true,
	[MovementStates.WallLeap] = true,
	[MovementStates.WallBoost] = true,
	[MovementStates.Vault] = true,
}

return {
	Grounded = Grounded,
	FlowBuilding = FlowBuilding,
	FlowHolding = FlowHolding,
}
