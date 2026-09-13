--!strict

-- Speed/jump tiers below are a starting point ("Fast & fluid" preset, chosen
-- 2026-09-13), not a final tuning pass -- retune after playtesting in Studio. See
-- docs/MOVEMENT.md §7 and commit a31e6d9 on why these aren't guessed placeholders.
local MovementConstants = {
	RunDoubleTapWindowSeconds = 0.3,
	SprintThresholdSeconds = 3,

	WalkSpeed = 18,
	RunSpeed = 28,
	SprintSpeed = 40,
	JumpPower = 55,
}

return MovementConstants
