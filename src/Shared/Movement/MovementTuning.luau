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
	| "SlideJumpBoostAmount"
	| "HardLandingFallSpeedThreshold"
	| "LandingAnimationHoldSeconds"
	| "DoubleJumpForce"
	| "DoubleJumpDecayDurationSeconds"

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
	SlideJumpBoostAmount: number,
	HardLandingFallSpeedThreshold: number,
	LandingAnimationHoldSeconds: number,
	DoubleJumpForce: number,
	DoubleJumpDecayDurationSeconds: number,
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
	"SlideJumpBoostAmount",
	"HardLandingFallSpeedThreshold",
	"LandingAnimationHoldSeconds",
	"DoubleJumpForce",
	"DoubleJumpDecayDurationSeconds",
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
	SlideJumpBoostAmount = { min = 0, max = 500 },
	HardLandingFallSpeedThreshold = { min = 0, max = 500 },
	LandingAnimationHoldSeconds = { min = 0, max = 5 },
	DoubleJumpForce = { min = 0, max = 500 },
	DoubleJumpDecayDurationSeconds = { min = 0.05, max = 5 },
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
		SlideJumpBoostAmount = MovementConstants.SlideJumpBoostAmount,
		HardLandingFallSpeedThreshold = MovementConstants.HardLandingFallSpeedThreshold,
		LandingAnimationHoldSeconds = MovementConstants.LandingAnimationHoldSeconds,
		DoubleJumpForce = MovementConstants.DoubleJumpForce,
		DoubleJumpDecayDurationSeconds = MovementConstants.DoubleJumpDecayDurationSeconds,
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
