--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)

export type FacingController = {
	Destroy: (self: FacingController) -> (),
}

local FacingController = {}
FacingController.__index = FacingController

-- Purely cosmetic (docs/MOVEMENT.md §4): aligns the root part's facing to the
-- camera/aim direction every frame, fully decoupled from movement direction.
-- Never touched by states or the FSM -- reads nothing from either.
function FacingController.new(rootPart: BasePart): FacingController
	local self = setmetatable({}, FacingController) :: any
	self._trove = Trove.new()
	self._rootPart = rootPart

	self._trove:Connect(RunService.RenderStepped, function()
		self:_update()
	end)

	return self
end

function FacingController:_update()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local lookVector = camera.CFrame.LookVector
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude == 0 then
		return
	end

	local rootPart = self._rootPart
	rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + flatLook)
end

function FacingController:Destroy()
	self._trove:Destroy()
end

return FacingController
