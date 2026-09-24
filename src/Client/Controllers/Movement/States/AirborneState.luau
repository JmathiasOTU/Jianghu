--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local LandingResolution = require(ReplicatedStorage.Shared.Movement.LandingResolution)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

local AirborneState = {}

AirborneState.CanEnter = StateRules.CanEnter[MovementStates.Airborne]

-- MediumLanding severity of the most recent landing this life, for
-- LocomotionAnimator's own getter-injection (same pattern as WallRunState.
-- GetEntrySide) -- set here, BEFORE `RequestTransition`/`changed:Fire` below,
-- so every `fsm.changed` subscriber sees it fresh regardless of connection
-- order.
local lastLandingWasMedium = false

-- Start-of-life reset (audit M-022), called by Movement/init.luau.
function AirborneState.Reset()
	lastLandingWasMedium = false
end

-- Wraps the shared landing-resolution logic (Shared/Movement/
-- LandingResolution.luau, unified there during the 2026-09-15 cleanup pass --
-- this used to be a full copy, hand-duplicated with the server's own
-- `resolveLandingTarget`) with the client-only MediumLanding effect
-- (animation + WalkSpeed slow, a third landing tier alongside the existing
-- light `Land` and real `HardLanding` state) -- deliberately NOT added to
-- the shared function itself, which stays a pure,
-- side-effect-free target-state lookup both client and server call
-- identically. DoubleJumpState and HardLandingState both call this same
-- wrapper (not `LandingResolution.Resolve` directly), so the effect fires
-- from every real landing edge without being duplicated per call site.
function AirborneState.ResolveLandingTarget(
	context: ClientMovementContext
): MovementStates.MovementState
	local target = LandingResolution.Resolve(context)
	local isMedium = target ~= MovementStates.HardLanding
		and context.fallHeight ~= nil
		and (context.fallHeight :: number) >= context.constants.MediumLandingHeightThreshold
	lastLandingWasMedium = isMedium
	if isMedium then
		context.characterMover:ApplyLandingSlow(
			context.constants.MediumLandingSpeedMultiplier,
			context.constants.MediumLandingDurationSeconds
		)
	end
	return target
end

function AirborneState.GetLastLandingWasMedium(): boolean
	return lastLandingWasMedium
end

function AirborneState.Enter(_context: ClientMovementContext) end

-- The decision lives in Update, not Exit: by the time Exit runs for the state
-- being left, RequestTransition has already committed to the next state
-- (StateMachine.luau fires `changed` after updating `current`), so Exit can
-- only ever be teardown, never the thing choosing where to land.
function AirborneState.Update(_dt: number, context: ClientMovementContext)
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end
end

function AirborneState.Exit(_context: ClientMovementContext) end

return AirborneState
