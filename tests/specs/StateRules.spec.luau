--!strict
local roblox = require("@lune/roblox")
local Fixtures = require("../fixtures")

local Vector3 = roblox.Vector3

return function(t)
	local StateRules = t.harness.require("ReplicatedStorage", "Shared", "Movement", "StateRules")
	local MovementStates = t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStates")

	local function canEnter(state: any, overrides: { [string]: any }): boolean
		return StateRules.CanEnter[state](Fixtures.context(overrides))
	end

	t.describe("topology", function()
		t.it("never lists a state as its own target", function()
			for state, targets in pairs(StateRules.Transitions) do
				t.expect(table.find(targets, state)).toBe(nil)
			end
		end)

		t.it("gives every state at least one way out", function()
			for _, targets in pairs(StateRules.Transitions) do
				t.expect(#targets).toBeAtLeast(1)
			end
		end)

		t.it("lets WallRun land into HardLanding (audit M-005)", function()
			local targets = StateRules.Transitions[MovementStates.WallRun]
			t.expect(table.find(targets, MovementStates.HardLanding) ~= nil).toBeTruthy()
		end)
	end)

	t.describe("CanEnter[WallRun]", function()
		local wall = Fixtures.wall("A")
		local alongWall = {
			grounded = false,
			wallRunQuery = {
				position = Vector3.zero,
				normal = Vector3.new(1, 0, 0),
				side = "Right",
				instance = wall,
			},
			horizontalVelocity = Vector3.new(0, 0, 30),
			moveIntent = Fixtures.moveIntent({ direction = Vector3.new(0, 0, 1), forward = true }),
		}

		t.it("accepts a fast run along a fresh wall", function()
			t.expect(canEnter(MovementStates.WallRun, alongWall)).toBeTruthy()
		end)

		t.it("rejects the wall just leapt from (audit M-037)", function()
			local overrides = table.clone(alongWall)
			overrides.lastWallLeapWall = wall
			t.expect(canEnter(MovementStates.WallRun, overrides)).toBeFalsy()
		end)

		t.it("accepts a different wall after a leap", function()
			local overrides = table.clone(alongWall)
			overrides.lastWallLeapWall = Fixtures.wall("B")
			t.expect(canEnter(MovementStates.WallRun, overrides)).toBeTruthy()
		end)

		t.it("rejects a standstill", function()
			local overrides = table.clone(alongWall)
			overrides.horizontalVelocity = Vector3.zero
			t.expect(canEnter(MovementStates.WallRun, overrides)).toBeFalsy()
		end)
	end)

	t.describe("CanEnter[WallCling]", function()
		local wall = Fixtures.wall("A")
		local headOn = {
			grounded = false,
			wallClingQuery = {
				instance = wall,
				position = Vector3.zero,
				normal = Vector3.new(0, 0, 1),
				distance = 1,
			},
			facingDirection = Vector3.new(0, 0, -1),
		}

		t.it("accepts facing a wall head-on", function()
			t.expect(canEnter(MovementStates.WallCling, headOn)).toBeTruthy()
		end)

		t.it("rejects side-on facing", function()
			local overrides = table.clone(headOn)
			overrides.facingDirection = Vector3.new(1, 0, 0)
			t.expect(canEnter(MovementStates.WallCling, overrides)).toBeFalsy()
		end)

		t.it("rejects during a lockout", function()
			local overrides = table.clone(headOn)
			overrides.wallClingLockoutUntil = os.clock() + 60
			t.expect(canEnter(MovementStates.WallCling, overrides)).toBeFalsy()
		end)
	end)

	t.describe("CanEnter[Sprint]", function()
		t.it("needs the full Run dwell", function()
			t.expect(canEnter(MovementStates.Sprint, { runDuration = 0.5 })).toBeFalsy()
			t.expect(canEnter(MovementStates.Sprint, { runDuration = 3 })).toBeTruthy()
		end)

		t.it("lets a landing resume a Sprint it already earned", function()
			t.expect(canEnter(MovementStates.Sprint, {
				preAirborneLocomotion = MovementStates.Sprint,
			})).toBeTruthy()
		end)
	end)

	t.describe("CanEnter[DoubleJump]", function()
		t.it("is once per airtime", function()
			t.expect(canEnter(MovementStates.DoubleJump, { grounded = false })).toBeTruthy()
			t.expect(canEnter(MovementStates.DoubleJump, {
				grounded = false,
				doubleJumpUsed = true,
			})).toBeFalsy()
		end)
	end)
end
