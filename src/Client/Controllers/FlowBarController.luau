--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local PresentationConstants = require(ReplicatedStorage.Shared.Constants.PresentationConstants)
local Spring = require(ReplicatedStorage.Shared.Util.Spring)

local DebugSnapshot = require(script.Parent.Parent.State.DebugSnapshot)

-- Test-only Flow meter (docs/MovementSystem.md §4.9): a vertical bar on the left edge that
-- fills with the local player's Flow. A placeholder until real HUD work, so
-- developer-only like the F4 overlay. The instance tree is
-- Assets/UI/FlowBar.model.json (ARCHITECTURE §8); this only drives it.
local FlowBarController = {}

function FlowBarController.Init()
	local player = Players.LocalPlayer
	if not DeveloperAllowlist.IsDeveloper(player) then
		return
	end

	local screenGui = player:WaitForChild("PlayerGui"):WaitForChild("FlowBar") :: ScreenGui
	local container = screenGui:WaitForChild("Container")
	local fill = container:WaitForChild("Track"):WaitForChild("Fill") :: Frame
	local valueLabel = container:WaitForChild("Value") :: TextLabel

	local fillSpring = Spring.number(
		PresentationConstants.FlowBarDampingRatio,
		PresentationConstants.FlowBarFrequency,
		0
	)
	screenGui.Enabled = true

	RunService.RenderStepped:Connect(function(dt: number)
		local flow = DebugSnapshot.Get().flow
		fillSpring:SetGoal(flow)
		fill.Size = UDim2.fromScale(1, math.clamp(fillSpring:Update(dt), 0, 1))
		valueLabel.Text = string.format("%d%%", math.round(flow * 100))
	end)
end

return FlowBarController
