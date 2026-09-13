--!strict

local Services = script.Parent.Services

for _, module in ipairs(Services:GetChildren()) do
	if module:IsA("ModuleScript") then
		local service = require(module) :: any
		if type(service) == "table" and service.Init then
			service.Init()
		end
	end
end
