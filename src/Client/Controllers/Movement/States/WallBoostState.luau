--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local AirborneState = require(script.Parent.AirborneState)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Instant impulse out of WallCling (docs/WallClimbingPlan.md §10.2): a single
-- one-shot AssemblyLinearVelocity write (SetHorizontalVelocity/
-- SetVerticalVelocity, NOT SetVelocityOverride -- WallClingState.Exit already
-- clears its own zero-velocity constraint before this Enter runs, and a
-- constraint left active here would have no Exit of its own to ever release
-- it, same reasoning WallLeapState's own launch already established), then a
-- short fixed window before handing back to Airborne.
local WallBoostState = {}

WallBoostState.CanEnter = StateRules.CanEnter[MovementStates.WallBoost]

local enteredAt: number? = nil

-- Start-of-life reset (audit M-022), called by Movement/init.luau.
function WallBoostState.Reset()
	enteredAt = nil
end

-- Wall normal comes from `context.wallClingNormal` (WallClingState's own
-- locked cling normal, captured into context BEFORE WallClingState.Exit nils
-- its own copy -- same pre-Exit-snapshot pattern `wallRunEntryInstance`
-- already established for the WallLeap edge), never read by calling
-- WallClingState directly.
function WallBoostState.Enter(context: ClientMovementContext)
	enteredAt = os.clock()

	local normal = context.wallClingNormal
	if normal then
		local velocity = TraversalMath.WallBoostVelocity(
			normal,
			context.constants.WallBoostUpwardForce,
			context.constants.WallBoostSeparationSpeed
		)
		context.characterMover:SetHorizontalVelocity(Vector3.new(velocity.X, 0, velocity.Z))
		context.characterMover:SetVerticalVelocity(velocity.Y)
	end

	-- Keeps a queued Space from immediately double-jumping over the impulse
	-- (docs/WallClimbingPlan.md §10.2) -- unblocked on Exit.
	context.characterMover:SetJumpBlocked(true)
end

-- Short window, not a control lock (docs/WallClimbingPlan.md §10.2) -- the
-- impulse was already fully applied in Enter, so Update only watches for the
-- window to end; it defines the duration the server mirrors (Phase 5).
function WallBoostState.Update(_dt: number, context: ClientMovementContext)
	if not enteredAt then
		return
	end

	-- Grounded check (docs/WallClimbingPlan.md §12, edge case 12) -- a boost
	-- launched near the ground, or one that clears a low ledge, can land
	-- before its own short duration window even elapses. Checked first, same
	-- priority every other airborne-family state's own Update gives it.
	if context.grounded then
		context.fsm:RequestTransition(AirborneState.ResolveLandingTarget(context), context)
		return
	end

	if os.clock() - enteredAt >= context.constants.WallBoostStateDuration then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
	end
end

function WallBoostState.Exit(context: ClientMovementContext)
	context.characterMover:SetJumpBlocked(false)
	enteredAt = nil
end

return WallBoostState
