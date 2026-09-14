--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)

export type FacingController = {
	Destroy: (self: FacingController) -> (),
}

local FacingController = {}
FacingController.__index = FacingController

-- Purely cosmetic (docs/MOVEMENT.md §4): aligns the root part's facing to the
-- camera/aim direction, but only while the camera is actually locked to the
-- character (Shift Lock or first-person) -- `UserInputService.MouseBehavior ==
-- LockCenter` covers both, and is the only reliable signal for this without
-- reaching into Roblox's default PlayerModule internals. Outside that, Humanoid's
-- own AutoRotate takes back over so free-orbiting the camera (not locked) doesn't
-- drag the character's facing with it -- bug fixed 2026-09-13: this used to force
-- camera-facing unconditionally, which fought normal camera orbiting when not
-- locked. Never touched by states or the FSM -- reads nothing from either.
function FacingController.new(humanoid: Humanoid, rootPart: BasePart): FacingController
	local self = setmetatable({}, FacingController) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._rootPart = rootPart

	self._trove:Connect(RunService.RenderStepped, function()
		self:_update()
	end)

	return self
end

function FacingController:_update()
	local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	self._humanoid.AutoRotate = not locked

	if not locked then
		return
	end

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
