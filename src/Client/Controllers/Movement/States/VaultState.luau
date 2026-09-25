--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.Core.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Mantle assist (docs/MovementSystem.md §4.8), in two phases inside one
-- state. The mantle drives the root up the wall face and across onto the
-- ledge over at most VaultMantleSeconds, less when already rising faster
-- (TraversalMath.VaultMantleDuration), as a full-force velocity override tracking
-- TraversalMath.VaultMantlePoint); then the launch writes a one-shot
-- camera-steered velocity, WallBoostState's shape, until VaultDurationSeconds.
-- The mantle replaced a one-frame PivotTo snap that read as a teleport.
local VaultState = {}

VaultState.CanEnter = StateRules.CanEnter[MovementStates.Vault]

local enteredAt: number? = nil
-- Persists past Exit: gates the next vault (cooldown) and DoubleJump
-- (VaultDoubleJumpBlockSeconds). The server keeps its own copy.
local lastVaultAt: number? = nil
local mantleStart: Vector3? = nil
local mantleTarget: Vector3? = nil
local mantleSeconds = 0
local ledgeDirection: Vector3? = nil
-- Taken on entry, before the mantle overrides velocity; the launch keeps a
-- share of it.
local entryVelocity = Vector3.zero
local launched = false

-- Start-of-life reset (audit M-022), called by Movement/init.luau.
function VaultState.Reset()
	enteredAt = nil
	lastVaultAt = nil
	mantleStart = nil
	mantleTarget = nil
	mantleSeconds = 0
	ledgeDirection = nil
	entryVelocity = Vector3.zero
	launched = false
end

function VaultState.GetLastVaultAt(): number?
	return lastVaultAt
end

local function launch(context: ClientMovementContext)
	launched = true
	local mover = context.characterMover
	mover:ClearVelocityOverride()

	local fallback = ledgeDirection or mover:GetFacingDirection()
	local constants = context.constants
	local direction = TraversalMath.VaultLaunchDirection(context.cameraLook or fallback, fallback)
	local velocity = TraversalMath.VaultLaunchVelocity(
		direction,
		entryVelocity,
		constants.VaultForwardSpeed,
		constants.VaultUpwardSpeed,
		constants.VaultHorizontalMomentumKeep,
		constants.VaultVerticalMomentumKeep,
		constants.VaultMaxMomentumUpward
	)
	mover:SetHorizontalVelocity(Vector3.new(velocity.X, 0, velocity.Z))
	mover:SetVerticalVelocity(velocity.Y)
	context.facingController:SetLockDirection(direction)
end

function VaultState.Enter(context: ClientMovementContext)
	enteredAt = os.clock()
	lastVaultAt = enteredAt
	launched = false

	local ledge = context.ledge
	if not ledge then
		return
	end
	local mover = context.characterMover

	local horizontal = mover:GetHorizontalVelocity()
	entryVelocity = Vector3.new(horizontal.X, mover:GetVerticalVelocity(), horizontal.Z)
	ledgeDirection = ledge.direction

	local start = mover:GetPosition()
	local target = ledge.topPoint
		+ Vector3.new(
			0,
			MovementConstants.RigRootHeightAboveFeet + MovementConstants.VaultMantleClearance,
			0
		)
	mantleStart = start
	mantleTarget = target
	mantleSeconds = TraversalMath.VaultMantleDuration(
		start,
		target,
		context.constants.VaultMantleSeconds,
		entryVelocity.Y
	)
	mover:SetVelocityOverride(TraversalMath.VaultMantleVelocity(start, target, 0, mantleSeconds))

	-- The Space press that triggered this can already have queued a Humanoid
	-- jump, which would replace the mantle or the launch; blocked until Exit.
	mover:SetJumpBlocked(true)
	-- Face into the wall while climbing it; the launch turns to its direction.
	context.facingController:SetLockDirection(-ledge.normal)
end

function VaultState.Update(dt: number, context: ClientMovementContext)
	if not enteredAt then
		return
	end
	local elapsed = os.clock() - enteredAt
	local constants = context.constants

	if not launched then
		local start, target = mantleStart, mantleTarget
		if start and target and elapsed < mantleSeconds and dt > 0 then
			-- Aim for where the path will be at the end of this step, so the
			-- root tracks it exactly and arrives on time.
			local ahead = TraversalMath.VaultMantlePoint(start, target, elapsed + dt, mantleSeconds)
			context.characterMover:SetVelocityOverride(
				(ahead - context.characterMover:GetPosition()) / dt
			)
			return
		end
		launch(context)
		-- This frame's `context.grounded` predates the launch.
		return
	end

	-- No landing checks until the window ends (2026-09-25 playtest): the feet
	-- pass just above the ledge, so a mid-vault read could resolve a landing
	-- (often a resumed Run) instead of handing to Airborne. The launch has
	-- the character rising when the window ends, so this is Airborne in
	-- practice; a landing here never resumes Run/Sprint.
	if elapsed < constants.VaultDurationSeconds then
		return
	end
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context, false), context)
	else
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	end
end

function VaultState.Exit(context: ClientMovementContext)
	context.characterMover:ClearVelocityOverride()
	context.characterMover:SetJumpBlocked(false)
	context.facingController:SetLockDirection(nil)
	enteredAt = nil
	mantleStart = nil
	mantleTarget = nil
	mantleSeconds = 0
	ledgeDirection = nil
	entryVelocity = Vector3.zero
	launched = false
end

return VaultState
