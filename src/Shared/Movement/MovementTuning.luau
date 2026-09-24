--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

-- Live-tunable subset of MovementConstants (F4 overlay "Tuning" tab,
-- docs/MOVEMENT.md) -- deliberately not every constant in that file (e.g.
-- SpeedCheckIntervalSeconds stays fixed), only the ones worth live-adjusting
-- while playtesting movement feel. Field names intentionally match
-- MovementConstants' own PascalCase keys 1:1 so a value can be read/written
-- with the same name on both sides -- no separate name-mapping table to keep
-- in sync.
export type TunableConstantName =
	"RunDoubleTapWindowSeconds"
	| "SprintThresholdSeconds"
	| "WalkSpeed"
	| "RunSpeed"
	| "SprintSpeed"
	| "JumpPower"
	| "SprintForwardDeadzone"
	| "SpeedToleranceMultiplier"
	| "CrouchSpeed"
	| "SlideDecayRate"
	| "SlideEntrySpeedMultiplier"
	| "SlideJumpBoostAmount"
	| "AnimationFadeTimeSeconds"
	| "LandingAnimationHoldSeconds"
	| "HardLandingHeightThreshold"
	| "HardLandingDurationSeconds"
	| "MediumLandingHeightThreshold"
	| "MediumLandingDurationSeconds"
	| "MediumLandingSpeedMultiplier"
	| "DoubleJumpForce"
	| "DoubleJumpDecayDurationSeconds"
	| "SlideSlopeAngleThresholdDegrees"
	| "SlideMaxWalkableSlopeDegrees"
	| "SlideSlopeAmplificationCap"
	| "SlideGroundRaycastThrottleSeconds"
	| "WallRunMinEntrySpeed"
	| "WallRunEntryDotThreshold"
	| "WallRunSpeed"
	| "WallRunSinkSpeed"
	| "WallRunClingDistance"
	| "WallRunClingCorrectionRate"
	| "WallRunClingMaxCorrectionSpeed"
	| "WallRunMaxNormalDeviationDegrees"
	| "WallRunMaxDurationSeconds"
	| "WallLeapBurstForce"
	| "WallLeapPushForce"
	| "WallLeapUpwardForce"
	| "WallClingMaxDuration"
	| "WallClingMaxFacingAngleDegrees"
	| "WallClingDropInputThreshold"
	| "WallClingTimeoutLockout"
	| "WallClingDropLockout"
	| "WallClingPostBoostCooldown"
	| "WallBoostUpwardForce"
	| "WallBoostSeparationSpeed"
	| "WallBoostStateDuration"

-- A named-field record (not a `{ [TunableConstantName]: number }` indexer
-- type) specifically so consumers get plain dot-access
-- (`context.constants.WalkSpeed`) at every one of the many call sites that
-- read a single, statically-known field -- the few places that need to read
-- or write one of these by a dynamically-held `TunableConstantName` (the
-- override-merge below, the overlay's Tuning-tab rows) index with `[name]`
-- instead, which Luau accepts on a record using any key type that's a
-- subtype of the record's own field names.
export type EffectiveMovementConstants = {
	RunDoubleTapWindowSeconds: number,
	SprintThresholdSeconds: number,
	WalkSpeed: number,
	RunSpeed: number,
	SprintSpeed: number,
	JumpPower: number,
	SprintForwardDeadzone: number,
	SpeedToleranceMultiplier: number,
	CrouchSpeed: number,
	SlideDecayRate: number,
	SlideEntrySpeedMultiplier: number,
	SlideJumpBoostAmount: number,
	AnimationFadeTimeSeconds: number,
	LandingAnimationHoldSeconds: number,
	HardLandingHeightThreshold: number,
	HardLandingDurationSeconds: number,
	MediumLandingHeightThreshold: number,
	MediumLandingDurationSeconds: number,
	MediumLandingSpeedMultiplier: number,
	DoubleJumpForce: number,
	DoubleJumpDecayDurationSeconds: number,
	SlideSlopeAngleThresholdDegrees: number,
	SlideMaxWalkableSlopeDegrees: number,
	SlideSlopeAmplificationCap: number,
	SlideGroundRaycastThrottleSeconds: number,
	WallRunMinEntrySpeed: number,
	WallRunEntryDotThreshold: number,
	WallRunSpeed: number,
	WallRunSinkSpeed: number,
	WallRunClingDistance: number,
	WallRunClingCorrectionRate: number,
	WallRunClingMaxCorrectionSpeed: number,
	WallRunMaxNormalDeviationDegrees: number,
	WallRunMaxDurationSeconds: number,
	WallLeapBurstForce: number,
	WallLeapPushForce: number,
	WallLeapUpwardForce: number,
	WallClingMaxDuration: number,
	WallClingMaxFacingAngleDegrees: number,
	WallClingDropInputThreshold: number,
	WallClingTimeoutLockout: number,
	WallClingDropLockout: number,
	WallClingPostBoostCooldown: number,
	WallBoostUpwardForce: number,
	WallBoostSeparationSpeed: number,
	WallBoostStateDuration: number,
}

-- Iteration order for the overlay's Tuning tab and for anything else that
-- needs to walk every tunable name deterministically.
local TUNABLE_NAMES: { TunableConstantName } = {
	"RunDoubleTapWindowSeconds",
	"SprintThresholdSeconds",
	"WalkSpeed",
	"RunSpeed",
	"SprintSpeed",
	"JumpPower",
	"SprintForwardDeadzone",
	"SpeedToleranceMultiplier",
	"CrouchSpeed",
	"SlideDecayRate",
	"SlideEntrySpeedMultiplier",
	"SlideJumpBoostAmount",
	"AnimationFadeTimeSeconds",
	"LandingAnimationHoldSeconds",
	"HardLandingHeightThreshold",
	"HardLandingDurationSeconds",
	"MediumLandingHeightThreshold",
	"MediumLandingDurationSeconds",
	"MediumLandingSpeedMultiplier",
	"DoubleJumpForce",
	"DoubleJumpDecayDurationSeconds",
	"SlideSlopeAngleThresholdDegrees",
	"SlideMaxWalkableSlopeDegrees",
	"SlideSlopeAmplificationCap",
	"SlideGroundRaycastThrottleSeconds",
	"WallRunMinEntrySpeed",
	"WallRunEntryDotThreshold",
	"WallRunSpeed",
	"WallRunSinkSpeed",
	"WallRunClingDistance",
	"WallRunClingCorrectionRate",
	"WallRunClingMaxCorrectionSpeed",
	"WallRunMaxNormalDeviationDegrees",
	"WallRunMaxDurationSeconds",
	"WallLeapBurstForce",
	"WallLeapPushForce",
	"WallLeapUpwardForce",
	"WallClingMaxDuration",
	"WallClingMaxFacingAngleDegrees",
	"WallClingDropInputThreshold",
	"WallClingTimeoutLockout",
	"WallClingDropLockout",
	"WallClingPostBoostCooldown",
	"WallBoostUpwardForce",
	"WallBoostSeparationSpeed",
	"WallBoostStateDuration",
}

-- Sanity bounds for RequestSetTuning (Server/Services/MovementTuningService.luau)
-- -- not a tuning decision in themselves, just wide-enough guardrails against a
-- value that would break the movement math outright (e.g. a negative speed, or
-- a SpeedToleranceMultiplier below 1x, which would make the sanity check
-- STRICTER than the tier it's supposed to grace and false-positive on ordinary
-- jitter -- the exact class of bug docs/MOVEMENT.md §5 already fixed once).
local VALID_RANGES: { [TunableConstantName]: { min: number, max: number } } = {
	RunDoubleTapWindowSeconds = { min = 0.05, max = 2 },
	SprintThresholdSeconds = { min = 0, max = 60 },
	WalkSpeed = { min = 0, max = 500 },
	RunSpeed = { min = 0, max = 500 },
	SprintSpeed = { min = 0, max = 500 },
	JumpPower = { min = 0, max = 500 },
	SprintForwardDeadzone = { min = -1, max = 1 },
	SpeedToleranceMultiplier = { min = 1, max = 10 },
	CrouchSpeed = { min = 0, max = 500 },
	SlideDecayRate = { min = 0.1, max = 500 },
	SlideEntrySpeedMultiplier = { min = 0.5, max = 5 },
	SlideJumpBoostAmount = { min = 0, max = 500 },
	AnimationFadeTimeSeconds = { min = 0, max = 2 },
	LandingAnimationHoldSeconds = { min = 0, max = 5 },
	-- Height threshold, not a speed -- wide enough to cover both a low-ceiling
	-- test map and a tall Qinggong-scale drop without needing a re-range later.
	HardLandingHeightThreshold = { min = 0, max = 2000 },
	-- Bounded well above the real ~1.11s clip length so a developer can still
	-- stretch it for testing, but can't zero it out into a permanent lock nor
	-- push it absurdly long by fat-fingering the F4 input box.
	HardLandingDurationSeconds = { min = 0.1, max = 10 },
	-- Same reasoning as HardLandingHeightThreshold above, just for the lower tier.
	MediumLandingHeightThreshold = { min = 0, max = 2000 },
	-- Same reasoning as HardLandingDurationSeconds above, tighter since the
	-- real clip is much shorter (~0.55s).
	MediumLandingDurationSeconds = { min = 0.05, max = 5 },
	-- A WalkSpeed multiplier, not a speed -- 0 pins it like HardLanding, 2 lets
	-- a developer experiment with a landing BOOST instead of a slow.
	MediumLandingSpeedMultiplier = { min = 0, max = 2 },
	DoubleJumpForce = { min = 0, max = 500 },
	DoubleJumpDecayDurationSeconds = { min = 0.05, max = 5 },
	SlideSlopeAngleThresholdDegrees = { min = 0, max = 89 },
	SlideMaxWalkableSlopeDegrees = { min = 0.1, max = 89 },
	SlideSlopeAmplificationCap = { min = 0, max = 500 },
	SlideGroundRaycastThrottleSeconds = { min = 0.02, max = 2 },
	WallRunMinEntrySpeed = { min = 0, max = 500 },
	WallRunEntryDotThreshold = { min = -1, max = 1 },
	WallRunSpeed = { min = 0, max = 500 },
	WallRunSinkSpeed = { min = 0, max = 200 },
	WallRunClingDistance = { min = 0, max = 20 },
	WallRunClingCorrectionRate = { min = 0, max = 100 },
	WallRunClingMaxCorrectionSpeed = { min = 0, max = 200 },
	WallRunMaxNormalDeviationDegrees = { min = 0, max = 89 },
	WallRunMaxDurationSeconds = { min = 0.1, max = 30 },
	WallLeapBurstForce = { min = 0, max = 200 },
	WallLeapPushForce = { min = 0, max = 200 },
	WallLeapUpwardForce = { min = 0, max = 200 },
	WallClingMaxDuration = { min = 0.1, max = 30 },
	WallClingMaxFacingAngleDegrees = { min = 0, max = 89 },
	WallClingDropInputThreshold = { min = -1, max = 1 },
	WallClingTimeoutLockout = { min = 0, max = 10 },
	WallClingDropLockout = { min = 0, max = 10 },
	WallClingPostBoostCooldown = { min = 0, max = 10 },
	WallBoostUpwardForce = { min = 0, max = 200 },
	WallBoostSeparationSpeed = { min = 0, max = 200 },
	-- Bounded well above the default ~0.12s window (mirrors
	-- MediumLandingDurationSeconds's own "wide enough to experiment, never
	-- zero or absurd" reasoning) -- lower bound isn't 0, so the window can
	-- always at least register on a real Heartbeat.
	WallBoostStateDuration = { min = 0.02, max = 5 },
}

local MovementTuning = {}

MovementTuning.Names = TUNABLE_NAMES

-- Fresh copy of the shipped values every time -- callers may freely mutate
-- what they get back without risking corrupting the one true default.
function MovementTuning.Defaults(): EffectiveMovementConstants
	return {
		RunDoubleTapWindowSeconds = MovementConstants.RunDoubleTapWindowSeconds,
		SprintThresholdSeconds = MovementConstants.SprintThresholdSeconds,
		WalkSpeed = MovementConstants.WalkSpeed,
		RunSpeed = MovementConstants.RunSpeed,
		SprintSpeed = MovementConstants.SprintSpeed,
		JumpPower = MovementConstants.JumpPower,
		SprintForwardDeadzone = MovementConstants.SprintForwardDeadzone,
		SpeedToleranceMultiplier = MovementConstants.SpeedToleranceMultiplier,
		CrouchSpeed = MovementConstants.CrouchSpeed,
		SlideDecayRate = MovementConstants.SlideDecayRate,
		SlideEntrySpeedMultiplier = MovementConstants.SlideEntrySpeedMultiplier,
		SlideJumpBoostAmount = MovementConstants.SlideJumpBoostAmount,
		AnimationFadeTimeSeconds = MovementConstants.AnimationFadeTimeSeconds,
		LandingAnimationHoldSeconds = MovementConstants.LandingAnimationHoldSeconds,
		HardLandingHeightThreshold = MovementConstants.HardLandingHeightThreshold,
		HardLandingDurationSeconds = MovementConstants.HardLandingDurationSeconds,
		MediumLandingHeightThreshold = MovementConstants.MediumLandingHeightThreshold,
		MediumLandingDurationSeconds = MovementConstants.MediumLandingDurationSeconds,
		MediumLandingSpeedMultiplier = MovementConstants.MediumLandingSpeedMultiplier,
		DoubleJumpForce = MovementConstants.DoubleJumpForce,
		DoubleJumpDecayDurationSeconds = MovementConstants.DoubleJumpDecayDurationSeconds,
		SlideSlopeAngleThresholdDegrees = MovementConstants.SlideSlopeAngleThresholdDegrees,
		SlideMaxWalkableSlopeDegrees = MovementConstants.SlideMaxWalkableSlopeDegrees,
		SlideSlopeAmplificationCap = MovementConstants.SlideSlopeAmplificationCap,
		SlideGroundRaycastThrottleSeconds = MovementConstants.SlideGroundRaycastThrottleSeconds,
		WallRunMinEntrySpeed = MovementConstants.WallRunMinEntrySpeed,
		WallRunEntryDotThreshold = MovementConstants.WallRunEntryDotThreshold,
		WallRunSpeed = MovementConstants.WallRunSpeed,
		WallRunSinkSpeed = MovementConstants.WallRunSinkSpeed,
		WallRunClingDistance = MovementConstants.WallRunClingDistance,
		WallRunClingCorrectionRate = MovementConstants.WallRunClingCorrectionRate,
		WallRunClingMaxCorrectionSpeed = MovementConstants.WallRunClingMaxCorrectionSpeed,
		WallRunMaxNormalDeviationDegrees = MovementConstants.WallRunMaxNormalDeviationDegrees,
		WallRunMaxDurationSeconds = MovementConstants.WallRunMaxDurationSeconds,
		WallLeapBurstForce = MovementConstants.WallLeapBurstForce,
		WallLeapPushForce = MovementConstants.WallLeapPushForce,
		WallLeapUpwardForce = MovementConstants.WallLeapUpwardForce,
		WallClingMaxDuration = MovementConstants.WallClingMaxDuration,
		WallClingMaxFacingAngleDegrees = MovementConstants.WallClingMaxFacingAngleDegrees,
		WallClingDropInputThreshold = MovementConstants.WallClingDropInputThreshold,
		WallClingTimeoutLockout = MovementConstants.WallClingTimeoutLockout,
		WallClingDropLockout = MovementConstants.WallClingDropLockout,
		WallClingPostBoostCooldown = MovementConstants.WallClingPostBoostCooldown,
		WallBoostUpwardForce = MovementConstants.WallBoostUpwardForce,
		WallBoostSeparationSpeed = MovementConstants.WallBoostSeparationSpeed,
		WallBoostStateDuration = MovementConstants.WallBoostStateDuration,
	}
end

-- Merges a (possibly nil, possibly partial) per-session override table over
-- the shipped defaults. Never mutates `overrides`.
function MovementTuning.WithOverrides(
	overrides: { [TunableConstantName]: number }?
): EffectiveMovementConstants
	local effective = MovementTuning.Defaults()
	if overrides then
		for name, value in overrides do
			effective[name] = value
		end
	end
	return effective
end

function MovementTuning.IsValidValue(name: TunableConstantName, value: number): boolean
	local range = VALID_RANGES[name]
	if not range then
		return false
	end
	if value ~= value or value == math.huge or value == -math.huge then
		-- NaN/inf can't come from a real Zap f32 write_check, but never trust
		-- a client-claimed number without checking anyway (docs/ARCHITECTURE.md §3).
		return false
	end
	return value >= range.min and value <= range.max
end

return MovementTuning
