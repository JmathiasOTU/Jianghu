--!strict

-- Speed/jump tiers (WalkSpeed, RunSpeed, SprintSpeed, JumpPower) are intentionally
-- absent until Step 2 gives them real, playtested values -- see docs/MOVEMENT.md §7
-- and commit a31e6d9 on why guessed numbers don't belong here.
local MovementConstants = {
	RunDoubleTapWindowSeconds = 0.3,
	SprintThresholdSeconds = 3,
}

return MovementConstants
