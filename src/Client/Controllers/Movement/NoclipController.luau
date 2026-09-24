--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.Packages.Trove)

local InputControllerModule = require(script.Parent.InputController)
type InputController = InputControllerModule.InputController

-- Scouting-tool constant, not a gameplay tunable -- not part of
-- Shared/Movement/MovementTuning.luau's list (docs/MovementSystem.md §10), since
-- noclip flight speed isn't a Walk/Run/Sprint tier a legitimate client is ever
-- validated against.
local FLY_SPEED = 60

export type NoclipController = {
	SetActive: (self: NoclipController, active: boolean) -> (),
	Destroy: (self: NoclipController) -> (),
}

local NoclipController = {}
NoclipController.__index = NoclipController

-- Collision is disabled server-side (DevToolsService.luau sets CanCollide on
-- every BasePart, which replicates natively) -- this only owns the actual fly
-- movement, driven client-side because the player's own character is already
-- network-owned by this client for ordinary movement (docs/MovementSystem.md §10).
-- `humanoid.PlatformStand = true` while active hands full control of the
-- character's position to this controller instead of Roblox's default ground
-- controller, which would otherwise fight these per-frame CFrame writes.
function NoclipController.new(
	humanoid: Humanoid,
	rootPart: BasePart,
	input: InputController
): NoclipController
	local self = setmetatable({}, NoclipController) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._rootPart = rootPart
	self._input = input
	self._active = false
	self._up = false
	self._down = false

	self._trove:Connect(
		UserInputService.InputBegan,
		function(inputObject: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then
				return
			end
			if inputObject.KeyCode == Enum.KeyCode.Space then
				self._up = true
			elseif inputObject.KeyCode == Enum.KeyCode.LeftControl then
				self._down = true
			end
		end
	)

	self._trove:Connect(UserInputService.InputEnded, function(inputObject: InputObject)
		if inputObject.KeyCode == Enum.KeyCode.Space then
			self._up = false
		elseif inputObject.KeyCode == Enum.KeyCode.LeftControl then
			self._down = false
		end
	end)

	self._trove:Connect(RunService.RenderStepped, function(dt: number)
		if not self._active then
			return
		end

		-- Cancel any gravity-accumulated velocity from the previous frame(s)
		-- before repositioning -- PlatformStand stops the Humanoid's own
		-- ground controller from fighting these writes, but the underlying
		-- part still integrates gravity every physics step otherwise.
		self._rootPart.AssemblyLinearVelocity = Vector3.zero

		local intent = self._input:GetMoveIntent()
		local vertical = (self._up and 1 or 0) - (self._down and 1 or 0)
		local move = intent.direction + Vector3.new(0, vertical, 0)
		if move.Magnitude > 0 then
			self._rootPart.CFrame += move.Unit * FLY_SPEED * dt
		end
	end)

	return self
end

function NoclipController:SetActive(active: boolean)
	if active == self._active then
		return
	end
	self._active = active
	self._humanoid.PlatformStand = active
	if not active then
		self._rootPart.AssemblyLinearVelocity = Vector3.zero
	end
end

function NoclipController:Destroy()
	self._trove:Destroy()
end

return NoclipController
