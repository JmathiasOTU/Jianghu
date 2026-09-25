--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

-- Live-tunable subset of MovementConstants (F4 overlay "Tuning" tab,
-- docs/MovementSystem.md) -- deliberately not every constant in that file (e.g.
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
	| "WallBoostMinClingSeconds"
	| "VaultForwardSpeed"
	| "VaultUpwardSpeed"
	| "VaultHorizontalMomentumKeep"
	| "VaultVerticalMomentumKeep"
	| "VaultMaxMomentumUpward"
	| "VaultDurationSeconds"
	| "VaultMantleSeconds"
	| "VaultMaxFacingAngleDegrees"
	| "VaultCooldownSeconds"
	| "VaultDoubleJumpBlockSeconds"

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
	WallBoostMinClingSeconds: number,
	VaultForwardSpeed: number,
	VaultUpwardSpeed: number,
	VaultHorizontalMomentumKeep: number,
	VaultVerticalMomentumKeep: number,
	VaultMaxMomentumUpward: number,
	VaultDurationSeconds: number,
	VaultMantleSeconds: number,
	VaultMaxFacingAngleDegrees: number,
	VaultCooldownSeconds: number,
	VaultDoubleJumpBlockSeconds: number,
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
	"WallBoostMinClingSeconds",
	"VaultForwardSpeed",
	"VaultUpwardSpeed",
	"VaultHorizontalMomentumKeep",
	"VaultVerticalMomentumKeep",
	"VaultMaxMomentumUpward",
	"VaultDurationSeconds",
	"VaultMantleSeconds",
	"VaultMaxFacingAngleDegrees",
	"VaultCooldownSeconds",
	"VaultDoubleJumpBlockSeconds",
}

-- Sanity bounds for RequestSetTuning (Server/Services/MovementTuningService.luau)
-- -- not a tuning decision in themselves, just wide-enough guardrails against a
-- value that would break the movement math outright (e.g. a negative speed).
-- Server validation tolerances are deliberately NOT in this set (audit M-017):
-- a live knob on one is exactly the "nudge a number until the false flag goes
-- away" pattern docs/ARCHITECTURE.md §9 forbids.
local VALID_RANGES: { [TunableConstantName]: { min: number, max: number } } = {
	RunDoubleTapWindowSeconds = { min = 0.05, max = 2 },
	SprintThresholdSeconds = { min = 0, max = 60 },
	WalkSpeed = { min = 0, max = 500 },
	RunSpeed = { min = 0, max = 500 },
	SprintSpeed = { min = 0, max = 500 },
	JumpPower = { min = 0, max = 500 },
	SprintForwardDeadzone = { min = -1, max = 1 },
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
	WallBoostMinClingSeconds = { min = 0, max = 5 },
	VaultForwardSpeed = { min = 0, max = 200 },
	VaultUpwardSpeed = { min = 0, max = 200 },
	VaultHorizontalMomentumKeep = { min = 0, max = 1 },
	VaultVerticalMomentumKeep = { min = 0, max = 1 },
	VaultMaxMomentumUpward = { min = 0, max = 200 },
	VaultDurationSeconds = { min = 0.02, max = 5 },
	VaultMantleSeconds = { min = 0.02, max = 2 },
	VaultMaxFacingAngleDegrees = { min = 0, max = 89 },
	VaultCooldownSeconds = { min = 0, max = 10 },
	VaultDoubleJumpBlockSeconds = { min = 0, max = 5 },
}

local MovementTuning = {}

MovementTuning.Names = TUNABLE_NAMES

-- Every tunable name must be a real numeric MovementConstants key with a
-- valid range -- checked once at require time, so a typo or a half-added key
-- fails loudly on load instead of reading nil in play (audit M-028).
for _, name in ipairs(TUNABLE_NAMES) do
	assert(
		type((MovementConstants :: any)[name]) == "number",
		`MovementTuning: "{name}" has no numeric MovementConstants value`
	)
	assert(VALID_RANGES[name] ~= nil, `MovementTuning: "{name}" has no VALID_RANGES entry`)
end

-- Fresh copy of the shipped values every time -- callers may freely mutate
-- what they get back without risking corrupting the one true default. Built
-- from TUNABLE_NAMES rather than listed by hand (audit M-028).
function MovementTuning.Defaults(): EffectiveMovementConstants
	local defaults = {}
	for _, name in ipairs(TUNABLE_NAMES) do
		defaults[name] = (MovementConstants :: any)[name]
	end
	return defaults :: any
end

-- The TuningState wire format (network.zap): one entry per tunable name, so
-- adding a tunable never touches the network schema or a hand-written mapper.
export type TuningEntry = { name: TunableConstantName, value: number }

function MovementTuning.ToEntries(constants: EffectiveMovementConstants): { TuningEntry }
	local entries = table.create(#TUNABLE_NAMES)
	for _, name in ipairs(TUNABLE_NAMES) do
		table.insert(entries, { name = name, value = constants[name] })
	end
	return entries
end

-- Starts from the shipped defaults so a missing entry can never leave a nil.
function MovementTuning.FromEntries(entries: { TuningEntry }): EffectiveMovementConstants
	local constants = MovementTuning.Defaults() :: any
	for _, entry in ipairs(entries) do
		if VALID_RANGES[entry.name] then
			constants[entry.name] = entry.value
		end
	end
	return constants
end

-- Merges a (possibly nil, possibly partial) per-session override table over
-- the shipped defaults. Never mutates `overrides`.
function MovementTuning.WithOverrides(
	overrides: { [TunableConstantName]: number }?
): EffectiveMovementConstants
	local effective = MovementTuning.Defaults()
	if overrides then
		for name, value in pairs(overrides) do
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
