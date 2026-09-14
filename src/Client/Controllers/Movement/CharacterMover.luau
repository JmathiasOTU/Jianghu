--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)

local GROUNDED_STATES = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

export type CharacterMover = {
	SetSpeed: (self: CharacterMover, speed: number) -> (),
	SetJumpPower: (self: CharacterMover, jumpPower: number) -> (),
	IsGrounded: (self: CharacterMover) -> boolean,
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

function CharacterMover:SetJumpPower(jumpPower: number)
	self._humanoid.JumpPower = jumpPower
end

function CharacterMover:IsGrounded(): boolean
	return GROUNDED_STATES[self._humanoid:GetState()] == true
end

function CharacterMover:Destroy()
	self._trove:Destroy()
end

return CharacterMover
