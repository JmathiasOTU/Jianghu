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

		t.it("reaches Vault from the air, a cling and a boost, never a wall run", function()
			for _, source in ipairs({
				MovementStates.Airborne,
				MovementStates.DoubleJump,
				MovementStates.WallCling,
				MovementStates.WallBoost,
			}) do
				local targets = StateRules.Transitions[source]
				t.expect(table.find(targets, MovementStates.Vault) ~= nil).toBeTruthy()
			end
			local fromWallRun = StateRules.Transitions[MovementStates.WallRun]
			t.expect(table.find(fromWallRun, MovementStates.Vault)).toBe(nil)
		end)

		t.it("lands from Vault back into Run or Sprint", function()
			local fromVault = StateRules.Transitions[MovementStates.Vault]
			t.expect(table.find(fromVault, MovementStates.Run) ~= nil).toBeTruthy()
			t.expect(table.find(fromVault, MovementStates.Sprint) ~= nil).toBeTruthy()
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
			facingDirection = Vector3.new(0, 0, 1),
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

		t.it("rejects backpedalling along the wall (facing away from the run)", function()
			local overrides = table.clone(alongWall)
			overrides.facingDirection = Vector3.new(0, 0, -1)
			overrides.moveIntent =
				Fixtures.moveIntent({ direction = Vector3.new(0, 0, 1), backward = true })
			t.expect(canEnter(MovementStates.WallRun, overrides)).toBeFalsy()
		end)

		t.it("rejects strafing along the wall (facing the wall)", function()
			local overrides = table.clone(alongWall)
			overrides.facingDirection = Vector3.new(-1, 0, 0)
			t.expect(canEnter(MovementStates.WallRun, overrides)).toBeFalsy()
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

	t.describe("CanEnter[Vault]", function()
		local cooldown = Fixtures.context().constants.VaultCooldownSeconds
		local headOn = {
			grounded = false,
			ledge = {
				instance = Fixtures.wall("A"),
				wallPoint = Vector3.zero,
				normal = Vector3.new(0, 0, 1),
				topPoint = Vector3.new(0, 4, -1.25),
				direction = Vector3.new(0, 0, -1),
			},
		}

		t.it("accepts a ledge ahead, in the air", function()
			t.expect(canEnter(MovementStates.Vault, headOn)).toBeTruthy()
		end)

		t.it("needs a ledge", function()
			t.expect(canEnter(MovementStates.Vault, { grounded = false })).toBeFalsy()
		end)

		t.it("rejects on the ground", function()
			local overrides = table.clone(headOn)
			overrides.grounded = true
			t.expect(canEnter(MovementStates.Vault, overrides)).toBeFalsy()
		end)

		t.it("judges the facing the probe was cast along", function()
			local overrides = table.clone(headOn)
			overrides.ledge = table.clone(headOn.ledge)
			overrides.ledge.direction = Vector3.new(1, 0, 0)
			t.expect(canEnter(MovementStates.Vault, overrides)).toBeFalsy()
		end)

		t.it("waits out the cooldown", function()
			local overrides = table.clone(headOn)
			overrides.lastVaultAt = os.clock()
			t.expect(canEnter(MovementStates.Vault, overrides)).toBeFalsy()
			overrides.lastVaultAt = os.clock() - cooldown - 0.01
			t.expect(canEnter(MovementStates.Vault, overrides)).toBeTruthy()
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

		t.it("is blocked briefly after a vault", function()
			local block = Fixtures.context().constants.VaultDoubleJumpBlockSeconds
			t.expect(canEnter(MovementStates.DoubleJump, {
				grounded = false,
				lastVaultAt = os.clock(),
			})).toBeFalsy()
			t.expect(canEnter(MovementStates.DoubleJump, {
				grounded = false,
				lastVaultAt = os.clock() - block - 0.01,
			})).toBeTruthy()
		end)
	end)

	t.describe("CanEnter[WallBoost]", function()
		local minCling = Fixtures.context().constants.WallBoostMinClingSeconds

		t.it("waits out the minimum cling time", function()
			t.expect(canEnter(MovementStates.WallBoost, { wallClingElapsed = 0 })).toBeFalsy()
			t.expect(canEnter(MovementStates.WallBoost, { wallClingElapsed = minCling - 0.01 }))
				.toBeFalsy()
			t.expect(canEnter(MovementStates.WallBoost, { wallClingElapsed = minCling }))
				.toBeTruthy()
		end)

		t.it("needs an active cling", function()
			t.expect(canEnter(MovementStates.WallBoost, {})).toBeFalsy()
		end)

		t.it("is once per cling", function()
			t.expect(canEnter(MovementStates.WallBoost, {
				wallClingElapsed = minCling,
				wallClingBoostUsed = true,
			})).toBeFalsy()
		end)
	end)

	t.describe("LedgeJump", function()
		local minSpeed = Fixtures.context().constants.LedgeJumpMinEntrySpeed
		local takeoff = {
			grounded = false,
			ledgeDropAhead = true,
			preAirborneLocomotion = MovementStates.Sprint,
			horizontalVelocity = Vector3.new(0, 0, -minSpeed),
		}

		local function with(changes: { [string]: any }): { [string]: any }
			local overrides = table.clone(takeoff)
			for key, value in pairs(changes) do
				overrides[key] = value
			end
			return overrides
		end

		t.it("accepts a jump takeoff from Sprint or Run with a drop ahead", function()
			t.expect(canEnter(MovementStates.LedgeJump, takeoff)).toBeTruthy()
			t.expect(
				canEnter(
					MovementStates.LedgeJump,
					with({ preAirborneLocomotion = MovementStates.Run })
				)
			).toBeTruthy()
		end)

		t.it("needs a drop ahead", function()
			t.expect(canEnter(MovementStates.LedgeJump, with({ ledgeDropAhead = false })))
				.toBeFalsy()
			local unprobed = table.clone(takeoff)
			unprobed.ledgeDropAhead = nil
			t.expect(canEnter(MovementStates.LedgeJump, unprobed)).toBeFalsy()
		end)

		t.it("never fires from a Walk or Idle takeoff", function()
			local walked = table.clone(takeoff)
			walked.preAirborneLocomotion = nil
			t.expect(canEnter(MovementStates.LedgeJump, walked)).toBeFalsy()
		end)

		t.it("needs real speed, not the tier's label", function()
			t.expect(canEnter(
				MovementStates.LedgeJump,
				with({
					horizontalVelocity = Vector3.new(0, 0, -(minSpeed - 0.01)),
				})
			)).toBeFalsy()
		end)

		t.it("rejects on the ground", function()
			t.expect(canEnter(MovementStates.LedgeJump, with({ grounded = true }))).toBeFalsy()
		end)

		t.it("is reached only from Airborne and only leaves to Airborne", function()
			for state, targets in pairs(StateRules.Transitions) do
				local reaches = table.find(targets, MovementStates.LedgeJump) ~= nil
				t.expect(reaches).toBe(state == MovementStates.Airborne)
			end
			local out = StateRules.Transitions[MovementStates.LedgeJump]
			t.expect(#out).toBe(1)
			t.expect(out[1]).toBe(MovementStates.Airborne)
		end)
	end)

	t.describe("claim sources", function()
		t.it("claims Run only from Idle/Walk and Sprint only from Run", function()
			for state in pairs(StateRules.Transitions) do
				local runOk = state == MovementStates.Idle or state == MovementStates.Walk
				t.expect(StateRules.CanClaimFrom(MovementStates.Run, state)).toBe(runOk)
				t.expect(StateRules.CanClaimFrom(MovementStates.Sprint, state))
					.toBe(state == MovementStates.Run)
			end
		end)

		t.it("never claims out of a HardLanding lock or a Vault", function()
			for _, source in ipairs({ MovementStates.HardLanding, MovementStates.Vault }) do
				t.expect(StateRules.CanClaimFrom(MovementStates.Run, source)).toBeFalsy()
				t.expect(StateRules.CanClaimFrom(MovementStates.Sprint, source)).toBeFalsy()
			end
		end)

		t.it("only claims along real edges", function()
			for claimed in pairs({ [MovementStates.Run] = true, [MovementStates.Sprint] = true }) do
				for source in pairs(StateRules.Transitions) do
					if StateRules.CanClaimFrom(claimed, source) then
						local targets = StateRules.Transitions[source]
						t.expect(table.find(targets, claimed) ~= nil).toBeTruthy()
					end
				end
			end
		end)
	end)
end
