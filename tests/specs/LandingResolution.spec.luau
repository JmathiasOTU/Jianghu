--!strict
local roblox = require("@lune/roblox")
local Fixtures = require("../fixtures")

local Vector3 = roblox.Vector3

return function(t)
	local LandingResolution =
		t.harness.require("ReplicatedStorage", "Shared", "Movement", "LandingResolution")
	local MovementStates = t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStates")

	local forwardIntent = Fixtures.moveIntent({ direction = Vector3.new(0, 0, -1), forward = true })
	local backwardIntent =
		Fixtures.moveIntent({ direction = Vector3.new(0, 0, 1), backward = true })

	local function resolve(overrides: { [string]: any }): any
		return LandingResolution.Resolve(Fixtures.context(overrides))
	end

	t.describe("Resolve", function()
		t.it("lands idle with no input", function()
			t.expect(resolve({})).toBe(MovementStates.Idle)
		end)

		t.it("forces HardLanding at the height threshold, whatever is held", function()
			local threshold = Fixtures.context().constants.HardLandingHeightThreshold
			t.expect(resolve({ fallHeight = threshold, crouchHeld = true }))
				.toBe(MovementStates.HardLanding)
			t.expect(resolve({ fallHeight = threshold - 1 })).toBe(MovementStates.Idle)
		end)

		t.it("lands crouched when Ctrl is held", function()
			t.expect(resolve({ crouchHeld = true })).toBe(MovementStates.CrouchIdle)
			t.expect(resolve({ crouchHeld = true, moveIntent = forwardIntent }))
				.toBe(MovementStates.CrouchWalk)
		end)

		t.it("resumes Sprint when forward is still held", function()
			t.expect(resolve({
				moveIntent = forwardIntent,
				preAirborneLocomotion = MovementStates.Sprint,
			})).toBe(MovementStates.Sprint)
		end)

		t.it("never resumes Run/Sprint when resume is off (Vault)", function()
			local context = Fixtures.context({
				moveIntent = forwardIntent,
				preAirborneLocomotion = MovementStates.Sprint,
			})
			t.expect(LandingResolution.Resolve(context, false)).toBe(MovementStates.Walk)
		end)

		t.it("demotes to Walk when landing backward", function()
			t.expect(resolve({
				moveIntent = backwardIntent,
				preAirborneLocomotion = MovementStates.Sprint,
			})).toBe(MovementStates.Walk)
		end)
	end)
end
