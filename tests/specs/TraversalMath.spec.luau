--!strict
-- The server's vertical ceiling and WallLeap allowance are only sound if these
-- bounds really bound what the client does, so each is checked against a
-- direct simulation of the client's own motion.
local roblox = require("@lune/roblox")

local Vector3 = roblox.Vector3
local GRAVITY = 196.2

return function(t)
	local TraversalMath =
		t.harness.require("ReplicatedStorage", "Shared", "Movement", "TraversalMath")
	local MovementConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "MovementConstants")

	t.describe("BallisticRise", function()
		t.it("is v^2 / 2g", function()
			t.expect(TraversalMath.BallisticRise(55, GRAVITY)).toBeCloseTo(55 * 55 / (2 * GRAVITY))
		end)

		t.it("is zero for a downward launch", function()
			t.expect(TraversalMath.BallisticRise(-30, GRAVITY)).toBe(0)
		end)
	end)

	t.describe("DoubleJumpVerticalVelocity", function()
		local force = MovementConstants.DoubleJumpForce
		local duration = MovementConstants.DoubleJumpDecayDurationSeconds
		local floor = MovementConstants.DoubleJumpDecayFloorFraction

		t.it("starts at full force", function()
			t.expect(TraversalMath.DoubleJumpVerticalVelocity(0, force, duration))
				.toBeCloseTo(force)
		end)

		t.it("decays to the floor fraction and holds there", function()
			t.expect(TraversalMath.DoubleJumpVerticalVelocity(duration, force, duration))
				.toBeCloseTo(force * floor)
			t.expect(TraversalMath.DoubleJumpVerticalVelocity(duration * 3, force, duration))
				.toBeCloseTo(force * floor)
		end)
	end)

	t.describe("DoubleJumpMaxRise", function()
		local force = MovementConstants.DoubleJumpForce
		local duration = MovementConstants.DoubleJumpDecayDurationSeconds
		local bound = TraversalMath.DoubleJumpMaxRise(force, duration, GRAVITY)

		-- The client re-samples the curve once per frame, holds that value for
		-- the whole frame, exits on the first frame at or past the duration,
		-- then flies ballistically from whatever velocity it last held.
		local function simulatedRise(frameSeconds: number): number
			local rise = 0
			local elapsed = 0
			local velocity = force
			while true do
				velocity = TraversalMath.DoubleJumpVerticalVelocity(elapsed, force, duration)
				rise += velocity * frameSeconds
				elapsed += frameSeconds
				if elapsed >= duration then
					break
				end
			end
			return rise + TraversalMath.BallisticRise(velocity, GRAVITY)
		end

		for _, fps in ipairs({ 240, 144, 60, 30, 20 }) do
			t.it(`bounds the client's rise at {fps} fps`, function()
				t.expect(simulatedRise(1 / fps)).toBeAtMost(bound)
			end)
		end
	end)

	-- The descent half of the vertical ceiling (re-audit N-002): an honest
	-- launch must stay under DescentCeiling(ceiling, apex time) for its whole
	-- flight, and anything that stops falling must eventually cross it.
	t.describe("DescentCeiling", function()
		t.it("holds at the apex height until the apex time", function()
			t.expect(TraversalMath.DescentCeiling(10, 2, 1, GRAVITY)).toBe(10)
			t.expect(TraversalMath.DescentCeiling(10, 2, 2, GRAVITY)).toBe(10)
		end)

		t.it("falls from rest under gravity after the apex time", function()
			t.expect(TraversalMath.DescentCeiling(10, 2, 2.5, GRAVITY))
				.toBeCloseTo(10 - GRAVITY * 0.25 / 2)
		end)

		t.it("is crossed by anything that hovers past the apex", function()
			local apexY = TraversalMath.BallisticRise(55, GRAVITY)
			local apexAt = TraversalMath.TimeToApex(55, GRAVITY)
			-- g * 0.1^2 / 2 ~= 0.98 studs below the apex after 0.1 s.
			t.expect(TraversalMath.DescentCeiling(apexY, apexAt, apexAt + 0.1, GRAVITY))
				.toBeAtMost(apexY - 0.9)
		end)

		-- Jump, WallLeap and WallBoost: one launch, then gravity alone.
		for _, speed in ipairs({
			MovementConstants.JumpPower,
			MovementConstants.WallLeapUpwardForce,
			MovementConstants.WallBoostUpwardForce,
		}) do
			t.it(`bounds a ballistic launch at {speed} studs/s`, function()
				local apexY = TraversalMath.BallisticRise(speed, GRAVITY)
				local apexAt = TraversalMath.TimeToApex(speed, GRAVITY)
				for step = 0, 400 do
					local time = step / 100
					local y = speed * time - GRAVITY * time * time / 2
					t.expect(y)
						.toBeAtMost(TraversalMath.DescentCeiling(apexY, apexAt, time, GRAVITY) + 1e-9)
				end
			end)
		end

		-- DoubleJump the way the client flies it: the curve re-sampled once a
		-- frame and held for that frame, released on the first frame at or
		-- past the duration, then ballistic from the last held velocity.
		local force = MovementConstants.DoubleJumpForce
		local duration = MovementConstants.DoubleJumpDecayDurationSeconds
		local apexY = TraversalMath.DoubleJumpMaxRise(force, duration, GRAVITY)
		local apexAt = TraversalMath.DoubleJumpTimeToApex(force, duration, GRAVITY)

		local function worstMargin(frameSeconds: number): number
			local y = 0
			local elapsed = 0
			local velocity = force
			local worst = math.huge
			local function check(time: number, height: number)
				worst = math.min(
					worst,
					TraversalMath.DescentCeiling(apexY, apexAt, time, GRAVITY) - height
				)
			end
			while true do
				velocity = TraversalMath.DoubleJumpVerticalVelocity(elapsed, force, duration)
				y += velocity * frameSeconds
				elapsed += frameSeconds
				check(elapsed, y)
				if elapsed >= duration then
					break
				end
			end
			for step = 1, 300 do
				local time = step / 100
				check(elapsed + time, y + velocity * time - GRAVITY * time * time / 2)
			end
			return worst
		end

		for _, fps in ipairs({ 240, 144, 60, 30, 20 }) do
			t.it(`bounds DoubleJump's whole flight at {fps} fps`, function()
				t.expect(worstMargin(1 / fps)).toBeAtLeast(0)
			end)
		end
	end)

	t.describe("WallLeapMaxHorizontalSpeed", function()
		local runSpeed = MovementConstants.WallRunSpeed
		local maxCorrection = MovementConstants.WallRunClingMaxCorrectionSpeed
		local burst = MovementConstants.WallLeapBurstForce
		local push = MovementConstants.WallLeapPushForce
		local bound = TraversalMath.WallLeapMaxHorizontalSpeed(runSpeed, maxCorrection, burst, push)

		-- Every horizontal velocity WallRun can hold (locked tangent speed plus
		-- a clamped correction along the normal), launched exactly the way
		-- WallLeapState does it.
		local function launchSpeed(correction: number): number
			local normal = Vector3.new(1, 0, 0)
			local tangent = Vector3.new(0, 0, 1)
			local current = tangent * runSpeed + normal * correction
			local velocity = TraversalMath.WallLeapVelocity(
				current.Unit,
				current.Magnitude,
				normal,
				burst,
				push,
				0
			)
			return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		end

		-- Vector3 is float32 (in Roblox and in Lune), so the client's launch is
		-- rounded to ~7 significant digits while the bound is computed in
		-- double precision. One float32 relative step is the only slack.
		local float32Slack = bound * 2 ^ -23

		t.it("bounds every launch WallRun can produce", function()
			local steps = 200
			for i = 0, steps do
				local correction = -maxCorrection + 2 * maxCorrection * i / steps
				t.expect(launchSpeed(correction)).toBeAtMost(bound + float32Slack)
			end
		end)

		t.it("is tight (reached at full outward correction)", function()
			t.expect(launchSpeed(maxCorrection)).toBeCloseTo(bound, float32Slack)
		end)
	end)

	t.describe("Vault", function()
		local forward = MovementConstants.VaultForwardSpeed
		local upward = MovementConstants.VaultUpwardSpeed
		local horizontalKeep = MovementConstants.VaultHorizontalMomentumKeep
		local verticalKeep = MovementConstants.VaultVerticalMomentumKeep
		local maxMomentum = MovementConstants.VaultMaxMomentumUpward
		local maxUpward = TraversalMath.VaultMaxUpwardSpeed(upward, maxMomentum)

		local function launch(direction: any, velocity: any): any
			return TraversalMath.VaultLaunchVelocity(
				direction,
				velocity,
				forward,
				upward,
				horizontalKeep,
				verticalKeep,
				maxMomentum
			)
		end

		t.it("probes often enough to catch a boost rising through the window", function()
			local window = MovementConstants.VaultMaxLedgeHeight
				- MovementConstants.VaultMinLedgeHeight
			local samples = MovementConstants.VaultAutoProbeSamplesPerWindow
			local rise = MovementConstants.WallBoostUpwardForce
			local interval = TraversalMath.VaultAutoProbeInterval(window, rise, samples)
			t.expect(rise * interval * samples).toBeAtMost(window + 1e-9)
			t.expect(TraversalMath.VaultAutoProbeInterval(window, 0, samples)).toBe(0)
		end)

		t.describe("mantle path", function()
			local start = Vector3.new(0, 0, 0)
			local target = Vector3.new(0, 6.5, -4)
			local duration = 0.2

			t.it("starts at the root and ends on the ledge", function()
				local first = TraversalMath.VaultMantlePoint(start, target, 0, duration)
				t.expect((first - start).Magnitude).toBeCloseTo(0, 1e-5)
				local last = TraversalMath.VaultMantlePoint(start, target, duration, duration)
				t.expect((last - target).Magnitude).toBeCloseTo(0, 1e-5)
			end)

			t.it("rises straight up before crossing, never above the target", function()
				for step = 0, 40 do
					local point = TraversalMath.VaultMantlePoint(
						start,
						target,
						duration * step / 40,
						duration
					)
					t.expect(point.Y).toBeAtMost(target.Y + 1e-5)
					if point.Y < target.Y - 1e-4 then
						t.expect(point.Z).toBeCloseTo(start.Z, 1e-5)
					end
				end
			end)

			t.it("keeps a faster rise instead of braking into the mantle", function()
				local length = target.Y + math.abs(target.Z)
				t.expect(TraversalMath.VaultMantleDuration(start, target, duration, 0))
					.toBe(duration)
				t.expect(TraversalMath.VaultMantleDuration(start, target, duration, 10))
					.toBe(duration)
				t.expect(TraversalMath.VaultMantleDuration(start, target, duration, 100))
					.toBeCloseTo(length / 100, 1e-6)
				t.expect(TraversalMath.VaultMantleDuration(start, target, duration, -80))
					.toBe(duration)
			end)

			t.it("moves at one constant speed for the whole duration", function()
				local speed = (target.Y + math.abs(target.Z)) / duration
				for _, elapsed in ipairs({ 0, 0.05, 0.15, 0.199 }) do
					local velocity =
						TraversalMath.VaultMantleVelocity(start, target, elapsed, duration)
					t.expect(velocity.Magnitude).toBeCloseTo(speed, 1e-3)
				end
				t.expect(
					TraversalMath.VaultMantleVelocity(start, target, duration, duration).Magnitude
				)
					.toBe(0)
			end)
		end)

		t.it("steers along the flattened camera look", function()
			local direction =
				TraversalMath.VaultLaunchDirection(Vector3.new(3, -4, 0), Vector3.new(0, 0, 1))
			t.expect(direction.X).toBeCloseTo(1)
			t.expect(direction.Y).toBe(0)
		end)

		t.it("falls back to the ledge direction for a vertical camera", function()
			local direction =
				TraversalMath.VaultLaunchDirection(Vector3.new(0, -1, 0), Vector3.new(0, 0, 2))
			t.expect(direction.Z).toBeCloseTo(1)
		end)

		-- Falls, rises and entry speeds up to the WallLeap allowance, in every
		-- direction the camera can steer.
		t.it("never launches faster than its bounds", function()
			local maxEntry = 170
			local slack = 1e-4
			for angle = 0, 350, 10 do
				local direction =
					Vector3.new(math.cos(math.rad(angle)), 0, math.sin(math.rad(angle)))
				for entry = 0, maxEntry, 10 do
					for vy = -300, 300, 25 do
						local velocity = launch(direction, Vector3.new(entry, vy, 0))
						t.expect(velocity.Y).toBeAtMost(maxUpward + slack)
						t.expect(Vector3.new(velocity.X, 0, velocity.Z).Magnitude).toBeAtMost(
							TraversalMath.VaultMaxHorizontalSpeed(forward, horizontalKeep, entry)
								+ slack
						)
					end
				end
			end
		end)

		t.it("gives a fast fall more lift, up to the cap", function()
			local still = launch(Vector3.new(1, 0, 0), Vector3.zero)
			local falling = launch(Vector3.new(1, 0, 0), Vector3.new(0, -30, 0))
			local plummeting = launch(Vector3.new(1, 0, 0), Vector3.new(0, -600, 0))
			t.expect(still.Y).toBeCloseTo(upward)
			t.expect(falling.Y).toBeCloseTo(upward + 30 * verticalKeep, 1e-4)
			t.expect(plummeting.Y).toBeCloseTo(maxUpward)
		end)

		-- The mantle lifts the root by up to VaultMaxLedgeHeight plus the
		-- clearance, then the launch flies ballistically from there.
		t.it("bounds the mantle plus the launch", function()
			local ledge = MovementConstants.VaultMaxLedgeHeight
				+ MovementConstants.VaultMantleClearance
			local apexY = TraversalMath.VaultMaxRise(ledge, maxUpward, GRAVITY)
			local apexAt = TraversalMath.TimeToApex(maxUpward, GRAVITY)
			for step = 0, 400 do
				local time = step / 100
				local y = ledge + maxUpward * time - GRAVITY * time * time / 2
				t.expect(y)
					.toBeAtMost(TraversalMath.DescentCeiling(apexY, apexAt, time, GRAVITY) + 1e-9)
			end
		end)
	end)
end
