--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local WallClingExitReasons = require(ReplicatedStorage.Shared.FSM.WallClingExitReasons)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext
type WallClingExitReason = WallClingExitReasons.WallClingExitReason

-- Static cling, no steered climbing (docs/WallClimbingPlan.md §10.1): zero
-- velocity via a full-force SetVelocityOverride (cancels gravity too, unlike
-- WallRun's controlled sink), jump blocked, facing snapped to the wall --
-- held until a hard time cap, a deliberate drop, the wall disappearing, or a
-- boost hand-off. Module-scope, not per-context, same single-local-player-FSM
-- pattern as WallRunState's own entry snapshot -- WallBoostState reads
-- `GetBoostUsed`/`GetLockoutUntil` off this module the same way WallLeapState
-- reads WallRunState's own GetEntry* accessors.
local WallClingState = {}

WallClingState.CanEnter = StateRules.CanEnter[MovementStates.WallCling]

local wall: BasePart? = nil
local normal: Vector3? = nil
local enteredAt: number? = nil
local recheckAccumulator = 0
local boostUsed = false
-- Persists PAST Exit, deliberately -- this is what gates the NEXT
-- Airborne -> WallCling attempt (StateRules.CanEnter[WallCling]'s own
-- lockout check), unlike every other module-local above which Exit nils out.
-- Server-owned; this is prediction only (docs/WallClimbingPlan.md §3.5).
local lockoutUntil: number? = nil
-- Set immediately before every RequestTransition call below, read (and
-- cleared) by Exit -- Exit itself has no other way to learn WHY it's being
-- called, since `context` carries no reason of its own.
local pendingExitReason: WallClingExitReason? = nil

function WallClingState.GetBoostUsed(): boolean
	return boostUsed
end

function WallClingState.GetLockoutUntil(): number?
	return lockoutUntil
end

function WallClingState.GetWall(): BasePart?
	return wall
end

function WallClingState.GetNormal(): Vector3?
	return normal
end

local function requestExit(
	context: ClientMovementContext,
	target: MovementStates.MovementState,
	reason: WallClingExitReason
): boolean
	pendingExitReason = reason
	return context.fsm:RequestTransition(target, context)
end

-- WallBoost's own entry point (docs/WallClimbingPlan.md §10.1 step 5) --
-- called from Movement/init.luau's `input.BoostRequested` connection (an
-- external input event, same "plain RequestTransition" shape as
-- `input.RunRequested`), NOT polled from this state's own Update. Routed
-- through `requestExit` (not a raw `fsm:RequestTransition`) so the `Boosted`
-- exit reason -- and with it, `WallClingPostBoostCooldown` -- is correctly
-- tagged on Exit; `boostUsed` flips only once the transition actually lands,
-- never speculatively, so a rejected attempt (already boosted, wrong state)
-- never burns the one-per-cling budget.
function WallClingState.RequestBoostTransition(context: ClientMovementContext): boolean
	local accepted = requestExit(context, MovementStates.WallBoost, WallClingExitReasons.Boosted)
	if accepted then
		boostUsed = true
	end
	return accepted
end

-- CanEnter already guarantees `context.wallClingQuery` is non-nil at the
-- moment this fires -- the `if not wallQuery` below is defensive typing, same
-- convention as WallRunState.Enter's own identical guard.
function WallClingState.Enter(context: ClientMovementContext)
	local wallQuery = context.wallClingQuery
	if not wallQuery then
		return
	end

	wall = wallQuery.instance
	normal = wallQuery.normal
	enteredAt = os.clock()
	recheckAccumulator = 0
	boostUsed = false

	context.characterMover:SetJumpBlocked(true)
	-- Omitting `maxForce` drives all three axes at full strength (docs/
	-- WallClimbingPlan.md §5's WallClingSpeedCeiling = 0 -- no horizontal
	-- drift, and no falling either, unlike WallRun's controlled sink).
	context.characterMover:SetVelocityOverride(Vector3.zero)

	-- Face into the wall (-normal), flattened -- the raw hit normal can carry
	-- a small Y component (bounded by WallClingMaxNormalY) that would tilt
	-- the character's pitch if passed through unflattened, same reasoning
	-- WallRunState's own locked tangent is always already flat.
	local flatInward = Vector3.new(-wallQuery.normal.X, 0, -wallQuery.normal.Z)
	if flatInward.Magnitude > 1e-3 then
		context.facingController:SetLockDirection(flatInward.Unit)
	end
end

-- Sustain checks, every tick (docs/WallClimbingPlan.md §10.1): timeout, drop
-- input, then the throttled wall-still-there recheck -- velocity is NOT
-- re-applied here (unlike WallRun's continuous cling correction): a single
-- Enter-time SetVelocityOverride to a constant Vector3.zero holds on its own
-- every physics step until Exit clears it, so there is nothing to recompute
-- per tick. F/WallBoost is wired centrally in Movement/init.luau (same
-- "external input event -> plain RequestTransition" shape as
-- input.RunRequested), not polled here.
function WallClingState.Update(dt: number, context: ClientMovementContext)
	if not enteredAt or not normal then
		return
	end

	-- Grounded check while clinging near the floor (docs/WallClimbingPlan.md
	-- §12, edge case 12) -- checked FIRST, same priority every other
	-- airborne-family state's own Update gives it (AirborneState/WallRunState
	-- both check `context.grounded` before anything else). `Interrupted`, not
	-- `WallLost` -- the wall didn't disappear, an external condition
	-- (touching ground) ended the cling -- either way applies no lockout.
	if context.grounded then
		requestExit(
			context,
			AirborneState.ResolveLandingTarget(context),
			WallClingExitReasons.Interrupted
		)
		return
	end

	if os.clock() - enteredAt >= context.constants.WallClingMaxDuration then
		requestExit(context, MovementStates.Airborne, WallClingExitReasons.Timeout)
		return
	end

	local moveDirection = context.moveIntent.direction
	if moveDirection.Magnitude > 0 then
		local flatAway = Vector3.new((normal :: Vector3).X, 0, (normal :: Vector3).Z)
		if
			flatAway.Magnitude > 1e-3
			and moveDirection.Unit:Dot(flatAway.Unit)
				>= context.constants.WallClingDropInputThreshold
		then
			requestExit(context, MovementStates.Airborne, WallClingExitReasons.Dropped)
			return
		end
	end

	recheckAccumulator += dt
	if recheckAccumulator >= MovementConstants.WallClingRecheckInterval then
		recheckAccumulator -= MovementConstants.WallClingRecheckInterval
		if not context.characterMover:QueryClingWall() then
			requestExit(context, MovementStates.Airborne, WallClingExitReasons.WallLost)
			return
		end
	end
end

function WallClingState.Exit(context: ClientMovementContext)
	local reason = pendingExitReason
	pendingExitReason = nil

	-- Only Timeout/Dropped/Boosted apply a re-grab lockout (docs/
	-- WallClimbingPlan.md §4's exit-reason table) -- WallLost/Interrupted (and
	-- an Enter that bailed out early with no wall) apply none, leaving
	-- whatever lockout is already in effect untouched.
	if reason == WallClingExitReasons.Timeout then
		lockoutUntil = os.clock() + context.constants.WallClingTimeoutLockout
	elseif reason == WallClingExitReasons.Dropped then
		lockoutUntil = os.clock() + context.constants.WallClingDropLockout
	elseif reason == WallClingExitReasons.Boosted then
		lockoutUntil = os.clock() + context.constants.WallClingPostBoostCooldown
	end

	context.characterMover:SetJumpBlocked(false)
	context.characterMover:ClearVelocityOverride()

	-- Root-cause fix, Phase 6 exploit audit (2026-09-19) -- see
	-- WallClingDropSeparationSpeed's own comment (MovementConstants.luau) for
	-- the full server-desync reasoning. Applied AFTER ClearVelocityOverride
	-- above, not before: the override constraint is still driving velocity to
	-- zero every physics step until it's actually cleared, so writing the
	-- nudge first would just get stomped by it the very next step.
	if reason == WallClingExitReasons.Dropped and normal then
		local flatAway = Vector3.new((normal :: Vector3).X, 0, (normal :: Vector3).Z)
		if flatAway.Magnitude > 1e-3 then
			context.characterMover:SetHorizontalVelocity(
				flatAway.Unit * MovementConstants.WallClingDropSeparationSpeed
			)
		end
	end

	context.facingController:SetLockDirection(nil)
	wall = nil
	normal = nil
	enteredAt = nil
	recheckAccumulator = 0
end

return WallClingState
