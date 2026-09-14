--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local TuningSnapshot = require(script.Parent.TuningSnapshot)

type MoveIntent = MovementTypes.MoveIntent

export type InputController = {
	RunRequested: LemonSignal.Signal<()>,
	GetMoveIntent: (self: InputController) -> MoveIntent,
	Destroy: (self: InputController) -> (),
}

local InputController = {}
InputController.__index = InputController

local KEY_TO_AXIS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.W] = "forward",
	[Enum.KeyCode.S] = "backward",
	[Enum.KeyCode.A] = "strafeLeft",
	[Enum.KeyCode.D] = "strafeRight",
}

-- Raw input -> Intent, per docs/MOVEMENT.md §1. Owns the W double-tap-to-Run
-- detector (the only discrete gesture in Phase 1's input set) and resolves the held
-- WASD axes into a camera-relative world-space direction every frame; the FSM/state
-- layer never touches UserInputService directly.
function InputController.new(): InputController
	local self = setmetatable({}, InputController) :: any
	self._trove = Trove.new()
	self.RunRequested = self._trove:Add(LemonSignal.new(), "Destroy")

	self._forward = false
	self._backward = false
	self._strafeLeft = false
	self._strafeRight = false
	self._lastWPressAt = nil :: number?

	self._trove:Connect(
		UserInputService.InputBegan,
		function(input: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then
				return
			end
			local axis = KEY_TO_AXIS[input.KeyCode]
			if not axis then
				return
			end
			(self :: any)["_" .. axis] = true

			if input.KeyCode == Enum.KeyCode.W then
				local now = os.clock()
				if
					self._lastWPressAt
					and now - self._lastWPressAt <= TuningSnapshot.Get().RunDoubleTapWindowSeconds
				then
					self.RunRequested:Fire()
					self._lastWPressAt = nil
				else
					self._lastWPressAt = now
				end
			end
		end
	)

	self._trove:Connect(
		UserInputService.InputEnded,
		function(input: InputObject, _gameProcessedEvent: boolean)
			local axis = KEY_TO_AXIS[input.KeyCode]
			if not axis then
				return
			end
			(self :: any)["_" .. axis] = false
		end
	)

	return self
end

function InputController:GetMoveIntent(): MoveIntent
	local forward = self._forward
	local backward = self._backward
	local strafeLeft = self._strafeLeft
	local strafeRight = self._strafeRight

	local axisX = (strafeRight and 1 or 0) - (strafeLeft and 1 or 0)
	local axisZ = (backward and 1 or 0) - (forward and 1 or 0)

	local direction = Vector3.zero
	local camera = Workspace.CurrentCamera
	if camera and (axisX ~= 0 or axisZ ~= 0) then
		local cameraCFrame = camera.CFrame
		local camForward = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		local camRight = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		if camForward.Magnitude > 0 and camRight.Magnitude > 0 then
			local resolved = camRight.Unit * axisX - camForward.Unit * axisZ
			if resolved.Magnitude > 0 then
				direction = resolved.Unit
			end
		end
	end

	return {
		direction = direction,
		forward = forward,
		backward = backward,
		strafeLeft = strafeLeft,
		strafeRight = strafeRight,
	}
end

function InputController:Destroy()
	self._trove:Destroy()
end

return InputController
