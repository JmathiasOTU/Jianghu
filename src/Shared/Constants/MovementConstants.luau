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
	-- replication jitter plus latency. Flagged unmeasured in the 2026-09-13
	-- rubber-banding investigation (docs/MOVEMENT.md §5/§9) -- left unchanged
	-- rather than guessed upward, since the reported bug turned out to be
	-- structural (stale FSM-mirror desync + a transition-boundary transient),
	-- not this number being too tight. Revisit only with real measured data from
	-- SPEED_SANITY_DEBUG_LOGGING (`MovementValidationService.luau`).
	SpeedToleranceMultiplier = 1.3,

	-- How forward-biased Sprint's continuation input must be to still count as
	-- "sprinting forward" rather than a backpedal/pure-strafe demotion, expressed
	-- as a dot-product threshold between facing and MoveDirection (1 = dead
	-- ahead, 0 = perpendicular). This is a gameplay-feel decision (like
	-- `SprintThresholdSeconds`), not a latency/replication tolerance: real WASD
	-- input only ever produces 0°, 45°, or 90°+ camera-relative angles (cos 0° =
	-- 1, cos 45° ≈ 0.707, cos 90° = 0), so any threshold comfortably between 0.707
	-- and 0 admits every legitimate forward-diagonal hold without change and only
	-- affects an angle no real keyboard combination can produce -- closing the
	-- gap where `MovementValidationService.classifyMoveIntent`'s old zero-crossing
	-- (`> 0`) let a spoofed `MoveDirection` with a razor-thin forward lean count
	-- as "forward" while moving almost entirely sideways (found 2026-09-13).
	SprintForwardDeadzone = 0.5,
}

return MovementConstants
