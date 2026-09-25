--!strict
-- network.zap's MovementStateName enum and Shared/FSM/MovementStateNames are
-- maintained by hand; the debug overlay and PlayMovementCue
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §5) both depend on them agreeing.
local fs = require("@lune/fs")

local function zapEnum(source: string, typeName: string): { [string]: boolean }
	local body = string.match(source, "type " .. typeName .. " = enum {(.-)}")
	assert(body, `network.zap has no enum {typeName}`)
	local names = {}
	for name in string.gmatch(body, '"([^"]+)"') do
		names[name] = true
	end
	return names
end

return function(t)
	local MovementStates = t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStates")
	local MovementStateNames =
		t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStateNames")

	t.describe("MovementStateNames", function()
		t.it("names every movement state", function()
			for key, state in pairs(MovementStates) do
				t.expect(MovementStateNames.DebugNames[state]).toBe(key)
			end
		end)

		t.it("matches network.zap's MovementStateName enum", function()
			local zapNames = zapEnum(fs.readFile("network.zap"), "MovementStateName")
			local count = 0
			for _, name in pairs(MovementStateNames.DebugNames) do
				t.expect(zapNames[name]).toBe(true)
				count += 1
			end
			for name in pairs(zapNames) do
				count -= 1
				t.expect(MovementStates[name] ~= nil).toBeTruthy()
			end
			t.expect(count).toBe(0)
		end)
	end)
end
