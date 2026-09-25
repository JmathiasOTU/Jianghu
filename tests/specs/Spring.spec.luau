--!strict
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local FRAME = 1 / 60

return function(t)
	local Spring = t.harness.require("ReplicatedStorage", "Shared", "Util", "Spring")

	local function runFor(spring: any, seconds: number, frameSeconds: number): (number, number)
		local position = spring:Update(0)
		local peak = position
		local elapsed = 0
		while elapsed < seconds do
			position = spring:Update(frameSeconds)
			peak = math.max(peak, position)
			elapsed += frameSeconds
		end
		return position, peak
	end

	t.describe("Spring", function()
		t.it("starts at rest at its initial value", function()
			local spring = Spring.number(1, 3, 70)
			t.expect(spring:Update(0)).toBe(70)
			t.expect(spring:Update(1)).toBe(70)
		end)

		for _, dampingRatio in ipairs({ 0.3, 1, 2 }) do
			t.it(`converges to its goal (damping {dampingRatio})`, function()
				local spring = Spring.number(dampingRatio, 3, 70)
				spring:SetGoal(82)
				local position = runFor(spring, 10, FRAME)
				t.expect(position).toBeCloseTo(82, 1e-3)
			end)
		end

		t.it("never overshoots when critically damped or overdamped", function()
			for _, dampingRatio in ipairs({ 1, 2 }) do
				local spring = Spring.number(dampingRatio, 3, 70)
				spring:SetGoal(82)
				local _, peak = runFor(spring, 3, FRAME)
				t.expect(peak).toBeAtMost(82 + 1e-9)
			end
		end)

		t.it("overshoots when underdamped", function()
			local spring = Spring.number(0.3, 3, 70)
			spring:SetGoal(82)
			local _, peak = runFor(spring, 3, FRAME)
			t.expect(peak).toBeAtLeast(82.5)
		end)

		t.it("lands in the same place whatever the frame rate", function()
			for _, dampingRatio in ipairs({ 0.3, 1, 2 }) do
				local oneStep = Spring.number(dampingRatio, 3, 70)
				local manySteps = Spring.number(dampingRatio, 3, 70)
				oneStep:SetGoal(82)
				manySteps:SetGoal(82)
				local expected = oneStep:Update(0.5)
				local actual = 0
				for _ = 1, 30 do
					actual = manySteps:Update(0.5 / 30)
				end
				t.expect(actual).toBeCloseTo(expected, 1e-9)
			end
		end)

		t.it("carries its velocity through a goal change instead of popping", function()
			local spring = Spring.number(1, 3, 70)
			spring:SetGoal(82)
			local before = spring:Update(0.1)
			spring:SetGoal(70)
			t.expect(spring:Update(0)).toBe(before)
			-- still rising for a moment, now curving back toward the new goal
			t.expect(spring:Update(FRAME)).toBeAtLeast(before)
		end)

		t.it("changes frequency without jumping", function()
			local slow = Spring.number(1, 1, 70)
			local fast = Spring.number(1, 1, 70)
			slow:SetGoal(82)
			fast:SetGoal(82)
			local before = fast:Update(0.1)
			slow:Update(0.1)
			fast:SetFrequency(4)
			t.expect(fast:Update(0)).toBe(before)
			t.expect(fast:Update(0.1)).toBeAtLeast(slow:Update(0.1))
		end)

		t.it("comes to rest where Reset puts it", function()
			local spring = Spring.number(1, 3, 70)
			spring:SetGoal(82)
			spring:Update(0.1)
			spring:Reset(75)
			t.expect(spring:Update(1)).toBe(75)
		end)

		t.it("springs Vector3s per axis", function()
			local spring = Spring.vector3(1, 4, Vector3.zero)
			spring:SetGoal(Vector3.new(1.75, 0, 0))
			local position = Vector3.zero
			for _ = 1, 600 do
				position = spring:Update(FRAME)
			end
			t.expect(position.X).toBeCloseTo(1.75, 1e-3)
			t.expect(position.Y).toBe(0)
			t.expect(position.Z).toBe(0)
		end)

		t.it("rejects a non-positive frequency or negative damping", function()
			t.expect(function()
				Spring.number(1, 0, 70)
			end).toThrow()
			t.expect(function()
				Spring.number(-0.1, 3, 70)
			end).toThrow()
		end)
	end)
end
