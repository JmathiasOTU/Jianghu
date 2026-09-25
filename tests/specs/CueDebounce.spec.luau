--!strict
return function(t)
	local CueDebounce =
		t.harness.require("ReplicatedStorage", "Shared", "Presentation", "CueDebounce")
	local PresentationConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "PresentationConstants")

	local floor = PresentationConstants.MinCueRetriggerSeconds

	local function debounceAt(): (any, (number) -> ())
		local now = 100
		local debounce = CueDebounce.new(function()
			return now
		end)
		return debounce, function(seconds: number)
			now += seconds
		end
	end

	t.describe("CueDebounce", function()
		t.it("fires a cue the first time", function()
			local debounce = debounceAt()
			t.expect(debounce:TryFire("HardLandingThud")).toBeTruthy()
		end)

		t.it("skips a replay inside the retrigger floor", function()
			local debounce, advance = debounceAt()
			debounce:TryFire("HardLandingThud")
			advance(floor / 2)
			t.expect(debounce:TryFire("HardLandingThud")).toBeFalsy()
		end)

		t.it("fires again once the floor has passed", function()
			local debounce, advance = debounceAt()
			debounce:TryFire("HardLandingThud")
			advance(floor)
			t.expect(debounce:TryFire("HardLandingThud")).toBeTruthy()
		end)

		t.it("measures from the last play, not the last attempt", function()
			local debounce, advance = debounceAt()
			debounce:TryFire("HardLandingThud")
			advance(floor * 0.6)
			debounce:TryFire("HardLandingThud")
			advance(floor * 0.6)
			t.expect(debounce:TryFire("HardLandingThud")).toBeTruthy()
		end)

		t.it("tracks each cue name separately", function()
			local debounce = debounceAt()
			debounce:TryFire("HardLandingThud")
			t.expect(debounce:TryFire("WallLeapBurst")).toBeTruthy()
		end)
	end)
end
