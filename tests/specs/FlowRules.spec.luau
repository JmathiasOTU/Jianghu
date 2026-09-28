--!strict
-- Flow only exists inside a sprint chain (docs/FLOW.md §0).
return function(t)
	local FlowRules = t.harness.require("ReplicatedStorage", "Shared", "Movement", "FlowRules")
	local MovementStates = t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStates")

	local S = MovementStates

	-- Walks a transition path from outside any chain; returns how many
	-- transitions gained Flow and whether the chain is still live at the end.
	local function run(path: { any }): (number, boolean)
		local inChain = false
		local gains = 0
		for _, next in ipairs(path) do
			inChain = FlowRules.ChainAfter(inChain, next)
			if FlowRules.Gains(inChain, next) then
				gains += 1
			end
		end
		return gains, inChain
	end

	t.describe("FlowRules", function()
		t.it("builds on moves chained from Sprint", function()
			local gains, inChain = run({
				S.Walk,
				S.Run,
				S.Sprint,
				S.Airborne,
				S.WallRun,
				S.WallLeap,
				S.Airborne,
				S.DoubleJump,
				S.Airborne,
			})
			t.expect(gains).toBe(3)
			t.expect(inChain).toBe(true)
		end)

		t.it("counts a slide jump out of a sprint slide", function()
			local gains = run({ S.Sprint, S.Slide, S.SlideJump, S.Airborne })
			t.expect(gains).toBe(1)
		end)

		t.it("never builds from a Walk or Run takeoff", function()
			t.expect((run({ S.Walk, S.Airborne, S.WallRun, S.WallLeap, S.Airborne, S.DoubleJump })))
				.toBe(0)
			t.expect((run({ S.Run, S.Airborne, S.WallRun, S.WallLeap, S.Airborne }))).toBe(0)
			t.expect((run({ S.Run, S.Slide, S.SlideJump, S.Airborne }))).toBe(0)
		end)

		t.it("survives a landing back into Sprint", function()
			local gains, inChain = run({ S.Sprint, S.Airborne, S.DoubleJump, S.Sprint, S.Airborne })
			t.expect(gains).toBe(1)
			t.expect(inChain).toBe(true)
		end)

		t.it("ends on touching down anywhere but Sprint", function()
			for _, landing in ipairs({
				S.Idle,
				S.Walk,
				S.Run,
				S.CrouchIdle,
				S.CrouchWalk,
				S.HardLanding,
			}) do
				local _, inChain = run({ S.Sprint, S.Airborne, landing })
				t.expect(inChain).toBe(false)
			end
		end)

		t.it("carries through a vault that lands back in Sprint", function()
			local gains, inChain =
				run({ S.Sprint, S.Airborne, S.Vault, S.Sprint, S.Airborne, S.WallRun })
			t.expect(gains).toBe(2)
			t.expect(inChain).toBe(true)
		end)

		t.it("ends after a vault that lands walking", function()
			local gains, inChain =
				run({ S.Sprint, S.Airborne, S.Vault, S.Walk, S.Airborne, S.WallRun })
			t.expect(gains).toBe(1)
			t.expect(inChain).toBe(false)
		end)
	end)
end
