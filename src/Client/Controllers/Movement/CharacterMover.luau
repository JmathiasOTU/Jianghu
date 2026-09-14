--!strict
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)

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
	SetJumpBlocked: (self: CharacterMover, blocked: boolean) -> (),
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

	return self
end

function CharacterMover:SetSpeed(speed: number)
	self._humanoid.WalkSpeed = speed
end

-- Real flattened horizontal velocity magnitude (docs/MOVEMENT.md §9), not
-- `humanoid.WalkSpeed` (the TARGET the ground controller is driving toward,
-- not what it's actually reached yet) -- Slide reads this once on Enter to
-- inherit "whatever speed you had at entry," which needs the true instant-in-
-- time speed, residual-momentum transients included, same
-- `AssemblyLinearVelocity`-flattening DebugSnapshot/enforceSpeedSanity
-- already use elsewhere for the same reason.
function CharacterMover:GetSpeed(): number
	local rootPart = self._humanoid.RootPart
	if not rootPart then
		return 0
	end
	local velocity = rootPart.AssemblyLinearVelocity
	return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
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

function CharacterMover:Destroy()
	if self._jumpBlocked then
		ContextActionService:UnbindAction(JUMP_BLOCK_ACTION_NAME)
	end
	self._trove:Destroy()
end

return CharacterMover
