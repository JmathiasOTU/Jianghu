--!strict
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)

-- Named binding for SetJumpBlocked below -- ContextActionService keys bindings
-- by name, so Bind/Unbind need to agree on the same string.
local JUMP_BLOCK_ACTION_NAME = "MovementJumpBlock"

local GROUNDED_STATES = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

export type CharacterMover = {
	SetSpeed: (self: CharacterMover, speed: number) -> (),
	GetSpeed: (self: CharacterMover) -> number,
	SetJumpPower: (self: CharacterMover, jumpPower: number) -> (),
	IsGrounded: (self: CharacterMover) -> boolean,
	IsJumping: (self: CharacterMover) -> boolean,
	GetVerticalVelocity: (self: CharacterMover) -> number,
	GetHorizontalVelocity: (self: CharacterMover) -> Vector3,
	SetHorizontalVelocity: (self: CharacterMover, velocity: Vector3) -> (),
	SetVerticalVelocity: (self: CharacterMover, y: number) -> (),
	GetFacingDirection: (self: CharacterMover) -> Vector3,
	GetRightDirection: (self: CharacterMover) -> Vector3,
	GetPosition: (self: CharacterMover) -> Vector3,
	SetJumpBlocked: (self: CharacterMover, blocked: boolean) -> (),
	SetVelocityOverride: (self: CharacterMover, velocity: Vector3, maxForce: Vector3?) -> (),
	ClearVelocityOverride: (self: CharacterMover) -> (),
	SetOrientationOverride: (self: CharacterMover, cframe: CFrame) -> (),
	ClearOrientationOverride: (self: CharacterMover) -> (),
	SetPositionHold: (self: CharacterMover, target: Vector3) -> (),
	ClearPositionHold: (self: CharacterMover) -> (),
	QueryGround: (self: CharacterMover, castDistance: number?) -> SpatialQueries.GroundQueryResult?,
	QueryWall: (self: CharacterMover, rayLength: number?) -> SpatialQueries.WallQueryResult?,
	GetLastWallQuery: (self: CharacterMover) -> SpatialQueries.WallQueryResult?,
	IsLedgeAbove: (self: CharacterMover, rayLength: number?) -> boolean,
	Destroy: (self: CharacterMover) -> (),
}

local CharacterMover = {}
CharacterMover.__index = CharacterMover

-- Narrow physics interface: states never touch the Humanoid directly (see
-- docs/MOVEMENT.md §4). Roblox's default character-control scripts already turn
-- WASD/Space into Humanoid:Move()/jumps -- this only owns the speed tier and
-- grounded-state read the FSM needs. RequestJump/Disable from the original design
-- are deliberately not here yet: nothing in Phase 1 needs to trigger a jump or
-- freeze movement programmatically. Add them when a state actually needs to (e.g.
-- a future forced-launch or stun), not speculatively now.
--
-- `jumpPower` is passed in rather than read from MovementConstants directly
-- (docs/MOVEMENT.md §8, live tuning) -- the caller (Movement/init.luau) sources
-- it from TuningSnapshot, this session's effective value, and re-pushes any
-- later change via SetJumpPower.

-- Backing constraint for SetVelocityOverride/ClearVelocityOverride
-- (TRAVERSAL-ROADMAP.md §2/§11, Phase 1's DoubleJump) -- created ONCE per
-- character life here, Trove-owned, left parented-but-inert (zero
-- MaxAxesForce) between uses, never re-instanced per move. This is the
-- structural fix over the reference controller, which does
-- `Instance.new("BodyVelocity")` per move and churns instances constantly.
-- `ForceLimitMode = PerAxis` + a per-axis `maxForce` (rather than a single
-- `LineForce` magnitude) is what lets a caller drive only SOME axes (e.g.
-- DoubleJump's vertical-only impulse) without fighting the Humanoid's own
-- WalkSpeed-driven horizontal movement on the other two.
local function createVelocityOverride(rootPart: BasePart): (Attachment, LinearVelocity)
	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementVelocityOverrideAttachment"
	attachment.Parent = rootPart

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "MovementVelocityOverride"
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	linearVelocity.MaxAxesForce = Vector3.zero
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = rootPart

	return attachment, linearVelocity
end

-- Backing constraints for SetOrientationOverride/ClearOrientationOverride and
-- SetPositionHold/ClearPositionHold (TRAVERSAL-ROADMAP.md §0/§2, Phase 4's
-- WallLatch) -- same "created ONCE per character life, Trove-owned, left
-- parented-but-inert between uses" treatment `createVelocityOverride` above
-- already established, just the two constraint kinds neither DoubleJump nor
-- Slide ever needed: `AlignOrientation` for "face this direction" (Dash
-- facing, WallLatch) and `AlignPosition` for "stick to this point in space"
-- (WallLatch's wall-snap, Vault's windup-lerp) -- §0's own decision record on
-- why a real position-hold constraint beats faking it out of zero-velocity
-- damping. `MaxTorque`/`MaxForce` are the inert switch here, the same role
-- `MaxAxesForce = Vector3.zero` plays for the LinearVelocity above -- zero
-- means "parented but applying no force at all" until the next Set call.
local function createOrientationOverride(rootPart: BasePart): (Attachment, AlignOrientation)
	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementOrientationOverrideAttachment"
	attachment.Parent = rootPart

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "MovementOrientationOverride"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.MaxTorque = 0
	alignOrientation.Responsiveness = 25
	alignOrientation.CFrame = CFrame.new()
	alignOrientation.Parent = rootPart

	return attachment, alignOrientation
end

local function createPositionHold(rootPart: BasePart): (Attachment, AlignPosition)
	local attachment = Instance.new("Attachment")
	attachment.Name = "MovementPositionHoldAttachment"
	attachment.Parent = rootPart

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "MovementPositionHold"
	alignPosition.Attachment0 = attachment
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.MaxForce = 0
	alignPosition.Responsiveness = 25
	alignPosition.Position = rootPart.Position
	alignPosition.Parent = rootPart

	return attachment, alignPosition
end

function CharacterMover.new(humanoid: Humanoid, jumpPower: number): CharacterMover
	local self = setmetatable({}, CharacterMover) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._jumpBlocked = false
	self._lastWallQuery = nil :: SpatialQueries.WallQueryResult?

	-- AutoRotate is NOT forced off here -- FacingController now owns it, toggling
	-- per-frame based on whether the camera is actually locked to the character
	-- (Shift Lock/first-person) vs. free-orbiting (docs/MOVEMENT.md §4, fixed
	-- 2026-09-13). Forcing it off unconditionally broke normal camera orbiting.
	humanoid.UseJumpPower = true
	humanoid.JumpPower = jumpPower

	local rootPart = humanoid.RootPart :: BasePart
	local attachment, linearVelocity = createVelocityOverride(rootPart)
	self._trove:Add(attachment)
	self._linearVelocity = self._trove:Add(linearVelocity)

	local orientationAttachment, alignOrientation = createOrientationOverride(rootPart)
	self._trove:Add(orientationAttachment)
	self._alignOrientation = self._trove:Add(alignOrientation)

	local positionAttachment, alignPosition = createPositionHold(rootPart)
	self._trove:Add(positionAttachment)
	self._alignPosition = self._trove:Add(alignPosition)

	return self
end

function CharacterMover:SetSpeed(speed: number)
	self._humanoid.WalkSpeed = speed
end

-- Real flattened horizontal velocity vector (docs/MOVEMENT.md §9, extended
-- TRAVERSAL-ROADMAP.md §8 Phase 3), not `humanoid.WalkSpeed` (the TARGET the
-- ground controller is driving toward, not what it's actually reached yet).
-- Slide's own Enter reads this to inherit both "whatever speed you had at
-- entry" (the magnitude, via GetSpeed below) AND "whatever direction you were
-- actually moving" (the raw vector, needed once Slide drives a real
-- `LinearVelocity` instead of just a WalkSpeed magnitude) -- residual-
-- momentum transients included, same `AssemblyLinearVelocity`-flattening
-- DebugSnapshot/enforceSpeedSanity already use elsewhere for the same reason.
function CharacterMover:GetHorizontalVelocity(): Vector3
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return Vector3.zero
	end
	local velocity = rootPart.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z)
end

-- Thin wrapper over `GetHorizontalVelocity` -- kept as its own method since
-- most callers (every grounded state's own decay/threshold checks) only ever
-- need the magnitude, not the direction.
function CharacterMover:GetSpeed(): number
	return self:GetHorizontalVelocity().Magnitude
end

-- Real flattened `rootPart.CFrame.LookVector` (docs/MOVEMENT.md §4/§12,
-- playtest feedback 2026-09-15) -- NOT a separate camera/input read of its
-- own, deliberately: `FacingController` already keeps the rootPart's actual
-- facing pointed at the camera's look direction every `RenderStepped` while
-- locked (Shift Lock/first-person), and `Humanoid.AutoRotate` already turns
-- it to face `MoveDirection` on its own when unlocked -- this just reads
-- whichever of those two is currently driving it, so Slide's steering (below)
-- gets "look/move direction" for free from systems that already exist,
-- without duplicating either one's logic or caring which mode is active.
function CharacterMover:GetFacingDirection(): Vector3
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return Vector3.zero
	end
	local lookVector = rootPart.CFrame.LookVector
	return Vector3.new(lookVector.X, 0, lookVector.Z)
end

-- WallRun's own left/right animation pick (TraversalMath.WallRunSide) needs
-- the character's current right vector alongside the wall's normal -- same
-- flattened-CFrame-read shape as GetFacingDirection above.
function CharacterMover:GetRightDirection(): Vector3
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return Vector3.zero
	end
	local rightVector = rootPart.CFrame.RightVector
	return Vector3.new(rightVector.X, 0, rightVector.Z)
end

-- WallLatch's own hold-height seed (TRAVERSAL-ROADMAP.md §8 Phase 4) -- the
-- one narrow rootPart-position read states need that none of the existing
-- methods already cover (added now because a state genuinely needs it, not
-- speculatively -- same standard this file's own top comment sets for
-- RequestJump/Disable).
function CharacterMover:GetPosition(): Vector3
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return Vector3.zero
	end
	return rootPart.Position
end

-- A single direct, one-shot physical write to `AssemblyLinearVelocity`'s
-- horizontal axes (docs/MOVEMENT.md's Y-component equivalent already reads
-- this same property elsewhere) -- NOT constraint-backed like
-- SetVelocityOverride, deliberately: this is for SlideJump's boosted launch
-- impulse, which fires once inside `SlideJumpState.Enter` the SAME frame it
-- transitions synchronously into Airborne, whose own Enter/Exit never runs a
-- real frame to clear anything (see SlideJumpState's own doc comment). A
-- constraint left active with no Exit to clear it would silently override
-- horizontal air control forever; a direct one-shot write just nudges the
-- body's real velocity via inertia and leaves the LinearVelocity constraint
-- untouched (already inert from Slide's own Exit clearing it first).
function CharacterMover:SetHorizontalVelocity(velocity: Vector3)
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return
	end
	local current = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(velocity.X, current.Y, velocity.Z)
end

-- The vertical-axis complement to `SetHorizontalVelocity` above -- same
-- direct, one-shot write (not constraint-backed), for the identical reason:
-- WallLeapState.Enter (mechanic 5a) transitions synchronously into
-- Airborne in the same call it fires from, so a constraint-backed
-- SetVelocityOverride would just get cleared by Exit before the physics
-- engine ever integrates it into real velocity (see SetHorizontalVelocity's
-- own doc comment -- SlideJumpState's boost hit the exact same problem).
function CharacterMover:SetVerticalVelocity(y: number)
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return
	end
	local current = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(current.X, y, current.Z)
end

function CharacterMover:SetJumpPower(jumpPower: number)
	self._humanoid.JumpPower = jumpPower
end

function CharacterMover:IsGrounded(): boolean
	return GROUNDED_STATES[self._humanoid:GetState()] == true
end

-- SlideJump's real entry gate (docs/MOVEMENT.md §9): by the time this reads
-- true, `IsGrounded` has already flipped false too -- both read off the same
-- single `Humanoid:GetState()`, which is only ever one state at a time -- so
-- this is what actually distinguishes "jumped out of a Slide" from "slid off
-- a ledge" (both otherwise look identical as "grounded -> not grounded").
function CharacterMover:IsJumping(): boolean
	return self._humanoid:GetState() == Enum.HumanoidStateType.Jumping
end

-- Real instant-in-time vertical speed (docs/MOVEMENT.md §10), mirroring
-- `GetSpeed`'s own doc comment exactly -- just the `Y` component instead of
-- the flattened `X`/`Z`. Landing-severity classification (Land vs LandHard)
-- reads this the instant Airborne exits, not a nominal constant.
function CharacterMover:GetVerticalVelocity(): number
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return 0
	end
	return rootPart.AssemblyLinearVelocity.Y
end

-- "Can't jump while crouched" (docs/MOVEMENT.md §9) blocks the jump INPUT
-- itself, not JumpPower/UseJumpPower -- those stay untouched so a real
-- SlideJump boost (which drives off WalkSpeed carrying into a normal jump,
-- see SlideJumpState) is unaffected. `ContextActionService:BindAction` on
-- `Enum.PlayerActions.CharacterJump`, sinking the result, is Roblox's own
-- documented way to disable the default `ControlModule`'s jump handling
-- without touching any Humanoid property -- CrouchIdle/CrouchWalk call this
-- on Enter/Exit, exactly the narrow on/off switch they need without reaching
-- into ContextActionService themselves.
function CharacterMover:SetJumpBlocked(blocked: boolean)
	if blocked == self._jumpBlocked then
		return
	end
	self._jumpBlocked = blocked
	if blocked then
		ContextActionService:BindAction(JUMP_BLOCK_ACTION_NAME, function()
			return Enum.ContextActionResult.Sink
		end, false, Enum.PlayerActions.CharacterJump)
	else
		ContextActionService:UnbindAction(JUMP_BLOCK_ACTION_NAME)
	end
end

-- Drives the rootPart toward `velocity` along whichever axes `maxForce`
-- actually allows (TRAVERSAL-ROADMAP.md §2) -- an axis with zero max force is
-- left entirely to the Humanoid's own WalkSpeed-driven movement, so e.g.
-- DoubleJump's `Vector3.new(0, maxForce.Y, 0)` only ever touches vertical
-- velocity. Omitting `maxForce` drives all three axes at full strength, for a
-- caller that genuinely wants to override the full vector (a future state's
-- choice to make, not this method's).
function CharacterMover:SetVelocityOverride(velocity: Vector3, maxForce: Vector3?)
	self._linearVelocity.VectorVelocity = velocity
	self._linearVelocity.MaxAxesForce = maxForce or Vector3.new(math.huge, math.huge, math.huge)
end

-- Leaves the constraint parented but inert (docs/MOVEMENT.md §11) -- zero
-- MaxAxesForce means it applies no force at all until the next
-- SetVelocityOverride, never destroyed/recreated between moves.
function CharacterMover:ClearVelocityOverride()
	self._linearVelocity.MaxAxesForce = Vector3.zero
	self._linearVelocity.VectorVelocity = Vector3.zero
end

-- WallLatch's facing-lock (TRAVERSAL-ROADMAP.md §2/§8 Phase 4) -- drives the
-- rootPart's orientation toward `cframe` via the AlignOrientation created
-- once in `.new` above, the same "constraint stays parented, only the
-- force/torque toggles" shape SetVelocityOverride already uses.
-- `math.huge` mirrors SetVelocityOverride's own "no maxForce given, drive at
-- full strength" default -- there's no partial-strength caller for
-- orientation the way DoubleJump's per-axis mask needed for velocity.
function CharacterMover:SetOrientationOverride(cframe: CFrame)
	self._alignOrientation.CFrame = cframe
	self._alignOrientation.MaxTorque = math.huge
end

function CharacterMover:ClearOrientationOverride()
	self._alignOrientation.MaxTorque = 0
end

-- WallLatch's wall-stick (TRAVERSAL-ROADMAP.md §0/§2/§8 Phase 4) -- via the
-- AlignPosition created once in `.new` above. This is the "genuinely need a
-- constraint built for holding a point in space, not a velocity-zeroing
-- workaround" case §0's own decision record calls out.
function CharacterMover:SetPositionHold(target: Vector3)
	self._alignPosition.Position = target
	self._alignPosition.MaxForce = math.huge
end

function CharacterMover:ClearPositionHold()
	self._alignPosition.MaxForce = 0
end

-- Slide's own ground-normal probe (TRAVERSAL-ROADMAP.md §8 Phase 3, mechanic
-- 3a) -- delegates straight to `Shared/Movement/SpatialQueries.QueryGround`,
-- the SAME pure function server-side resimulation calls, seeded from this
-- CharacterMover's own rootPart/character so states never need direct
-- rootPart access themselves (docs/MOVEMENT.md §4's "states never touch the
-- Humanoid directly" boundary, extended to the RootPart it owns).
function CharacterMover:QueryGround(castDistance: number?): SpatialQueries.GroundQueryResult?
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return nil
	end
	return SpatialQueries.QueryGround(rootPart, self._humanoid.Parent :: Instance, castDistance)
end

-- WallRun/WallLatch's own wall probe (TRAVERSAL-ROADMAP.md §8 Phase 4) --
-- same delegation shape as QueryGround above, the SAME pure function server
-- resimulation calls too (Shared/Movement/SpatialQueries.QueryWall). Casts
-- along `humanoid.MoveDirection` (flattened), not facing -- facing lags real
-- movement input while the camera is unlocked. Caches its own result as a
-- side effect (`GetLastWallQuery`) so a consumer with no per-Heartbeat
-- context of its own (LocomotionAnimator) can read the current wall without
-- firing a redundant raycast.
function CharacterMover:QueryWall(rayLength: number?): SpatialQueries.WallQueryResult?
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		self._lastWallQuery = nil
		return nil
	end
	local moveDirection = self._humanoid.MoveDirection
	local castDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	local result = SpatialQueries.QueryWall(rootPart, self._humanoid.Parent :: Instance, castDirection, rayLength)
	self._lastWallQuery = result
	return result
end

function CharacterMover:GetLastWallQuery(): SpatialQueries.WallQueryResult?
	return self._lastWallQuery
end

-- Top-out probe (mechanic 5) -- same delegation shape, same MoveDirection
-- cast direction as QueryWall above.
function CharacterMover:IsLedgeAbove(rayLength: number?): boolean
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return false
	end
	local moveDirection = self._humanoid.MoveDirection
	local castDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	return SpatialQueries.QueryLedgeAbove(rootPart, self._humanoid.Parent :: Instance, castDirection, rayLength)
end

function CharacterMover:Destroy()
	if self._jumpBlocked then
		ContextActionService:UnbindAction(JUMP_BLOCK_ACTION_NAME)
	end
	self._trove:Destroy()
end

return CharacterMover
