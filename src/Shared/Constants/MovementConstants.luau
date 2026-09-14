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

	-- MovementValidationService's server-side speed/delta-position sanity check
	-- (docs/MOVEMENT.md §5, Step 4): sampled over this interval rather than every
	-- Heartbeat, to smooth over normal CFrame-replication jitter from the
	-- network-owning client.
	SpeedCheckIntervalSeconds = 0.5,
	-- Grace multiplier on top of the current tier's speed cap for that same
	-- replication jitter plus latency -- not a gameplay value, tune only if the
	-- sanity check false-positives or lets real speed hacks slip through.
	SpeedToleranceMultiplier = 1.3,
}

return MovementConstants
