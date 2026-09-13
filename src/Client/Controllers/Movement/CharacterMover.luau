--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.Trove)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local GROUNDED_STATES = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
	[Enum.HumanoidStateType.Landed] = true,
}

export type CharacterMover = {
	SetSpeed: (self: CharacterMover, speed: number) -> (),
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
function CharacterMover.new(humanoid: Humanoid): CharacterMover
	local self = setmetatable({}, CharacterMover) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid

	humanoid.AutoRotate = false
	humanoid.UseJumpPower = true
	humanoid.JumpPower = MovementConstants.JumpPower

	return self
end

function CharacterMover:SetSpeed(speed: number)
	self._humanoid.WalkSpeed = speed
end

function CharacterMover:IsGrounded(): boolean
	return GROUNDED_STATES[self._humanoid:GetState()] == true
end

function CharacterMover:Destroy()
	self._trove:Destroy()
end

return CharacterMover
