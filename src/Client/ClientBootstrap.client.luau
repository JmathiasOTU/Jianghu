--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Controllers = script.Parent.Controllers

for _, module in ipairs(Controllers:GetChildren()) do
	if module:IsA("ModuleScript") then
		local controller = require(module) :: any
		if type(controller) == "table" and controller.Init then
			controller.Init()
		end
	end
end
