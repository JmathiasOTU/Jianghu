--!strict
return function(t)
	local MovementTuning =
		t.harness.require("ReplicatedStorage", "Shared", "Movement", "MovementTuning")
	local MovementConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "MovementConstants")

	t.describe("MovementTuning", function()
		t.it("defaults every tunable to its shipped constant", function()
			local defaults = MovementTuning.Defaults()
			for _, name in ipairs(MovementTuning.Names) do
				t.expect(defaults[name]).toBe(MovementConstants[name])
			end
		end)

		t.it("round-trips the TuningState wire format", function()
			local constants = MovementTuning.Defaults()
			constants.WalkSpeed = 21
			local decoded = MovementTuning.FromEntries(MovementTuning.ToEntries(constants))
			for _, name in ipairs(MovementTuning.Names) do
				t.expect(decoded[name]).toBe(constants[name])
			end
		end)

		t.it("ignores names it doesn't know on decode", function()
			local decoded =
				MovementTuning.FromEntries({ { name = "NotATunable", value = 1 } } :: any)
			t.expect(decoded.NotATunable).toBe(nil)
		end)

		t.it("keeps validation tolerances off the live-tuning surface (audit M-017)", function()
			t.expect(table.find(MovementTuning.Names, "SpeedToleranceMultiplier")).toBe(nil)
		end)

		t.it("rejects NaN, infinity and out-of-range values", function()
			t.expect(MovementTuning.IsValidValue("WalkSpeed", 0 / 0)).toBeFalsy()
			t.expect(MovementTuning.IsValidValue("WalkSpeed", math.huge)).toBeFalsy()
			t.expect(MovementTuning.IsValidValue("WalkSpeed", -1)).toBeFalsy()
			t.expect(MovementTuning.IsValidValue("WalkSpeed", 20)).toBeTruthy()
		end)
	end)
end
