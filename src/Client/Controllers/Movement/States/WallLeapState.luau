--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local ClientMovementContextModule = require(script.Parent.Parent.ClientMovementContext)
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- Single-frame launch out of WallRun (Wall Run & Leap Mechanic Guideline
-- §4) -- same shape as SlideJumpState's own boost: Enter applies the launch
-- impulse and immediately hands off to Airborne in the SAME synchronous call
-- (RequestTransition fires `fsm.changed` reentrantly, which LemonSignal runs
-- via `task.spawn` -- effectively synchronous as long as nothing yields,
-- which nothing here does), so Update/Exit never actually run for a real
-- frame. No CanEnter[WallLeap] exists -- topology alone gates the
-- WallRun -> WallLeap edge (StateRules.luau), the same "you have to actually
-- be wall-running" legality WallLeap's own StateRules.Transitions comment
-- already explains. Entered via a plain `fsm:RequestTransition(WallLeap,
-- context)` from the unified JumpRequested handler, not a bespoke bypass --
-- SlideJump's own precedent already proves a normal CanEnter-less topology
-- edge is enough for a one-tick launch-then-handoff shape.
local WallLeapState = {}

-- Applied via SetHorizontalVelocity + SetVerticalVelocity, one-shot writes --
-- NOT SetVelocityOverride: WallRunState.Exit already clears the constraint
-- (runs before this Enter, per Movement/init.luau's shared Exit/Enter
-- context), and a constraint-backed write here would have no Exit of its own
-- to ever clear it, silently locking velocity for the rest of the fall (the
-- identical reasoning SlideJumpState's own boost already established).
--
-- Direction/magnitude come from the character's REAL current horizontal
-- velocity (redesigned 2026-09-18: a momentum-burst launch, not the original
-- retention-scaled forward + push-off + lift curve) -- WallRunState.Exit
-- clears the velocity-override constraint but never touches
-- AssemblyLinearVelocity itself, so this reads the same physical velocity
-- the run was actually holding, one exit->enter call apart, before any
-- Heartbeat re-simulates it. Falls back to `wallRunEntryTangent` (WallRunState's
-- own locked-at-entry snapshot, exposed via `context` the same way
-- `slideSpeed`/`slideDirection` already are) only for the degenerate
-- zero-velocity case, which real play never actually hits. `wallRunEntryNormal`
-- still comes from that same snapshot -- the push-off direction is the wall's
-- own normal, never a live re-read (guideline §0's "locked at Entry" rule).
function WallLeapState.Enter(context: ClientMovementContext)
	local normal = context.wallRunEntryNormal
	if not normal then
		context.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	local currentVelocity = context.characterMover:GetHorizontalVelocity()
	local direction = if currentVelocity.Magnitude > 0
		then currentVelocity.Unit
		else context.wallRunEntryTangent or Vector3.zero

	local velocity = TraversalMath.WallLeapVelocity(
		direction,
		currentVelocity.Magnitude,
		normal,
		context.constants.WallLeapBurstForce,
		context.constants.WallLeapPushForce,
		context.constants.WallLeapUpwardForce
	)
	context.characterMover:SetHorizontalVelocity(Vector3.new(velocity.X, 0, velocity.Z))
	context.characterMover:SetVerticalVelocity(velocity.Y)

	context.fsm:RequestTransition(MovementStates.Airborne, context)
end

function WallLeapState.Update(_dt: number, _context: ClientMovementContext) end

function WallLeapState.Exit(_context: ClientMovementContext) end

return WallLeapState
