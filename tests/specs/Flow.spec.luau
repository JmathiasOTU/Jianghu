--!strict
-- Flow (docs/MovementSystem.md §4.9) raises enforced caps, so the server's copy has to stay
-- at or above the client's, and the raised bounds still have to bound what
-- the client actually does.
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3

return function(t)
	local TraversalMath =
		t.harness.require("ReplicatedStorage", "Shared", "Movement", "TraversalMath")
	local MovementConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "MovementConstants")

	local gain = MovementConstants.FlowGainPerMove
	local bonus = MovementConstants.FlowMaxSpeedBonus
	local delay = MovementConstants.FlowDecayDelaySeconds
	local rate = MovementConstants.FlowDecayRate

	t.describe("FlowAfterGain", function()
		t.it("adds one step", function()
			t.expect(TraversalMath.FlowAfterGain(0, gain)).toBeCloseTo(gain)
		end)

		t.it("clamps at 1", function()
			t.expect(TraversalMath.FlowAfterGain(0.9, 0.5)).toBe(1)
		end)
	end)

	t.describe("FlowAfterDecay", function()
		t.it("holds inside the delay", function()
			t.expect(TraversalMath.FlowAfterDecay(0.6, delay * 0.99, 0.1, delay, rate)).toBe(0.6)
		end)

		t.it("drains linearly after the delay", function()
			t.expect(TraversalMath.FlowAfterDecay(0.6, delay, 0.1, delay, rate))
				.toBeCloseTo(0.6 - rate * 0.1)
		end)

		t.it("never goes below zero", function()
			t.expect(TraversalMath.FlowAfterDecay(0.01, delay, 1, delay, rate)).toBe(0)
		end)

		t.it("drains full Flow in the delay plus 1 / rate", function()
			local dt = 1 / 60
			local flow = 1
			local elapsed = 0
			while flow > 0 do
				elapsed += dt
				flow = TraversalMath.FlowAfterDecay(flow, elapsed, dt, delay, rate)
			end
			t.expect(elapsed).toBeCloseTo(delay + 1 / rate, 2 * dt)
		end)
	end)

	t.describe("FlowMultiplier", function()
		t.it("is 1 with no Flow and 1 + bonus at full Flow", function()
			t.expect(TraversalMath.FlowMultiplier(0, bonus)).toBe(1)
			t.expect(TraversalMath.FlowMultiplier(1, bonus)).toBeCloseTo(1 + bonus)
		end)
	end)

	-- Real claims arrive in order, each 0 to `maxLag` late; the server drains
	-- `maxLag` later than the client (Flow.Decay). Between arrivals it must
	-- never sit below the client, or its caps would correct legitimate speed.
	-- A gain still in flight is covered by the claim latency credit instead.
	t.describe("server Flow vs client Flow", function()
		local maxLag = MovementConstants.SpeedCheckIntervalSeconds

		local seed = 12345
		local function random(): number
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed / 2147483648
		end

		local function worstShortfall(
			gainStep: number,
			decayDelay: number,
			decayRate: number
		): number
			local worst = 0
			local dt = 1 / 60
			for _ = 1, 150 do
				local sent: { number } = {}
				local arrived: { number } = {}
				local at = 0
				for i = 1, 8 do
					at += 0.1 + random() * 4
					sent[i] = at
					arrived[i] = math.max(at + random() * maxLag, arrived[i - 1] or 0)
				end

				local client, server = 0, 0
				local clientGainAt, serverGainAt = 0, 0
				local nextClient, nextServer = 1, 1
				local now = 0
				while now < at + decayDelay + maxLag + 1 / decayRate + 1 do
					now += dt
					client = TraversalMath.FlowAfterDecay(
						client,
						now - clientGainAt,
						dt,
						decayDelay,
						decayRate
					)
					while sent[nextClient] and sent[nextClient] <= now do
						client = TraversalMath.FlowAfterGain(client, gainStep)
						clientGainAt = now
						nextClient += 1
					end
					while arrived[nextServer] and arrived[nextServer] <= now do
						server = TraversalMath.FlowAfterGain(server, gainStep)
						serverGainAt = now
						nextServer += 1
					end
					server = TraversalMath.FlowAfterDecay(
						server,
						now - serverGainAt,
						dt,
						decayDelay + maxLag,
						decayRate
					)
					if nextClient == nextServer then
						worst = math.max(worst, client - server)
					end
				end
			end
			return worst
		end

		t.it("never trails the client at shipped tuning", function()
			t.expect(worstShortfall(gain, delay, rate)).toBeAtMost(1e-9)
		end)

		t.it("never trails the client with no delay and a fast drain", function()
			t.expect(worstShortfall(0.5, 0, 2)).toBeAtMost(1e-9)
		end)
	end)

	t.describe("raised bounds", function()
		local multiplier = TraversalMath.FlowMultiplier(1, bonus)

		t.it("WallLeap's bound covers a leap off a full-Flow wall run", function()
			local runSpeed = MovementConstants.WallRunSpeed * multiplier
			local maxCorrection = MovementConstants.WallRunClingMaxCorrectionSpeed
			local burst = MovementConstants.WallLeapBurstForce
			local push = MovementConstants.WallLeapPushForce
			local bound =
				TraversalMath.WallLeapMaxHorizontalSpeed(runSpeed, maxCorrection, burst, push)
			local normal = Vector3.new(1, 0, 0)
			local tangent = Vector3.new(0, 0, 1)
			for i = 0, 200 do
				local correction = -maxCorrection + 2 * maxCorrection * i / 200
				local current = tangent * runSpeed + normal * correction
				local velocity = TraversalMath.WallLeapVelocity(
					current.Unit,
					current.Magnitude,
					normal,
					burst,
					push,
					0
				)
				t.expect(Vector3.new(velocity.X, 0, velocity.Z).Magnitude)
					.toBeAtMost(bound * (1 + 2 ^ -23))
			end
		end)

		-- SlideJumpState: min(slide + boost, max(ceiling at live Flow, slide)),
		-- where the slide started under the server's held multiplier.
		t.it("a slide jump never beats the server's held-Flow slide ceiling", function()
			local sprint = MovementConstants.SprintSpeed
			local entry = MovementConstants.SlideEntrySpeedMultiplier
			local boost = MovementConstants.SlideJumpBoostAmount
			for heldStep = 0, 10 do
				local held = TraversalMath.FlowMultiplier(heldStep / 10, bonus)
				local serverCeiling = TraversalMath.SlideCeiling(sprint, entry, held)
				for liveStep = 0, heldStep do
					local live = TraversalMath.FlowMultiplier(liveStep / 10, bonus)
					for slideStep = 0, 20 do
						local slide = serverCeiling * slideStep / 20
						local ceiling =
							math.max(TraversalMath.SlideCeiling(sprint, entry, live), slide)
						t.expect(math.min(slide + boost, ceiling)).toBeAtMost(serverCeiling + 1e-9)
					end
				end
			end
		end)
	end)
end
