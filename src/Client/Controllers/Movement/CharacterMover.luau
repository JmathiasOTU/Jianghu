--!strict
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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
	ApplyLandingSlow: (self: CharacterMover, multiplier: number, duration: number) -> (),
	SetJumpPower: (self: CharacterMover, jumpPower: number) -> (),
	IsGrounded: (self: CharacterMover) -> boolean,
	IsJumping: (self: CharacterMover) -> boolean,
	GetVerticalVelocity: (self: CharacterMover) -> number,
	GetHorizontalVelocity: (self: CharacterMover) -> Vector3,
	SetHorizontalVelocity: (self: CharacterMover, velocity: Vector3) -> (),
	SetVerticalVelocity: (self: CharacterMover, velocity: number) -> (),
	GetFacingDirection: (self: CharacterMover) -> Vector3,
	GetPosition: (self: CharacterMover) -> Vector3,
	NudgeIntoWall: (self: CharacterMover, offset: Vector3) -> (),
	SetJumpBlocked: (self: CharacterMover, blocked: boolean) -> (),
	SetVelocityOverride: (self: CharacterMover, velocity: Vector3, maxForce: Vector3?) -> (),
	ClearVelocityOverride: (self: CharacterMover) -> (),
	QueryGround: (self: CharacterMover, castDistance: number?) -> SpatialQueries.GroundQueryResult?,
	QueryWallRun: (
		self: CharacterMover,
		castRadius: number?,
		castDistance: number?
	) -> SpatialQueries.WallRunQueryResult?,
	QueryClingWall: (self: CharacterMover) -> SpatialQueries.ClingWallHit?,
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

function CharacterMover.new(humanoid: Humanoid, jumpPower: number): CharacterMover
	local self = setmetatable({}, CharacterMover) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._jumpBlocked = false

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

	-- MediumLanding's WalkSpeed slow (ApplyLandingSlow below) needs to wear
	-- off on its own timer even if the player never changes state during the
	-- window (SetSpeed is only ever called again on the NEXT state's Enter,
	-- which wouldn't happen for a while if they just keep walking) -- so this
	-- re-applies `_baseSpeed * penalty` every Heartbeat instead of leaving the
	-- discounted WalkSpeed stuck until the next unrelated transition.
	self._baseSpeed = 0
	self._speedPenaltyMultiplier = 1
	self._speedPenaltyUntil = 0
	self._trove:Connect(RunService.Heartbeat, function()
		self:_applySpeed()
	end)

	return self
end

function CharacterMover:_applySpeed()
	local multiplier = if os.clock() < self._speedPenaltyUntil
		then self._speedPenaltyMultiplier
		else 1
	self._humanoid.WalkSpeed = self._baseSpeed * multiplier
end

function CharacterMover:SetSpeed(speed: number)
	self._baseSpeed = speed
	self:_applySpeed()
end

-- MediumLanding (no FSM state of its own -- see
-- AirborneState.ResolveLandingTarget): a temporary WalkSpeed multiplier,
-- transparent to every caller of SetSpeed above, so no individual state
-- needs to know landing recovery is happening.
function CharacterMover:ApplyLandingSlow(multiplier: number, duration: number)
	self._speedPenaltyMultiplier = multiplier
	self._speedPenaltyUntil = os.clock() + duration
	self:_applySpeed()
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

-- WallRun's cling-snap needs the character's real current position to
-- compute how far off the wall it is (Wall Run & Leap Mechanic Guideline
-- §3) -- same narrow-accessor treatment as GetHorizontalVelocity/
-- GetVerticalVelocity above, so states still never touch the RootPart
-- directly.
function CharacterMover:GetPosition(): Vector3
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return Vector3.zero
	end
	return rootPart.Position
end

-- WallRun's one-time Enter-time cling snap (guideline §3) -- a direct,
-- one-shot position write via PivotTo (moves the whole Model, not a bare
-- rootPart.CFrame write, so Motor6D-welded limbs never desync), same
-- category of move as the existing dev-teleport handler, just a couple of
-- studs instead of a level-spanning jump.
function CharacterMover:NudgeIntoWall(offset: Vector3)
	local character = self._humanoid.Parent
	if not character or not character:IsA("Model") then
		return
	end
	character:PivotTo(character:GetPivot() + offset)
end

-- Vertical-axis complement to SetHorizontalVelocity above (WallLeap's launch,
-- guideline §4) -- same direct one-shot write, deliberately NOT constraint-
-- backed: WallLeapState's Enter transitions synchronously into Airborne in
-- the same call (no real frame for Exit to ever clear a constraint), the
-- identical reasoning SlideJumpState's own boost already established.
function CharacterMover:SetVerticalVelocity(velocity: number)
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return
	end
	local current = rootPart.AssemblyLinearVelocity
	rootPart.AssemblyLinearVelocity = Vector3.new(current.X, velocity, current.Z)
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
--
-- The input sink alone isn't enough (HardLanding jump-spam bug): a state
-- entered on the Heartbeat AFTER touchdown (HardLanding) arrives one physics
-- step too late -- a Space spammed mid-fall has already queued
-- `Humanoid.Jump`, which fires Landed -> Jumping on the very next step no
-- matter what the input layer sinks from then on. Disabling the `Jumping`
-- HumanoidState (client-authoritative for the owning client) and clearing
-- the queued flag closes that gap at the physics level; clearing it again on
-- unblock drops any press buffered during the lock instead of auto-jumping
-- the instant it ends (a still-held Space re-asserts it next frame anyway).
function CharacterMover:SetJumpBlocked(blocked: boolean)
	if blocked == self._jumpBlocked then
		return
	end
	self._jumpBlocked = blocked
	self._humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not blocked)
	self._humanoid.Jump = false
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

-- WallRun's own side-cast probe (Wall Run & Leap Mechanic Guideline §1) --
-- same delegation shape as QueryGround above, just to SpatialQueries.QueryWallRun.
function CharacterMover:QueryWallRun(
	castRadius: number?,
	castDistance: number?
): SpatialQueries.WallRunQueryResult?
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return nil
	end
	return SpatialQueries.QueryWallRun(
		rootPart,
		self._humanoid.Parent :: Instance,
		castRadius,
		castDistance
	)
end

-- WallCling's own forward probe (docs/WallClimbingPlan.md §7) -- same
-- delegation shape as QueryGround/QueryWallRun above, just to
-- SpatialQueries.castClingWall.
function CharacterMover:QueryClingWall(): SpatialQueries.ClingWallHit?
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return nil
	end
	return SpatialQueries.castClingWall(rootPart, self._humanoid.Parent :: Instance)
end

function CharacterMover:Destroy()
	if self._jumpBlocked then
		self:SetJumpBlocked(false)
	end
	self._trove:Destroy()
end

return CharacterMover
