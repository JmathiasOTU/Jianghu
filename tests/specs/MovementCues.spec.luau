--!strict
-- Catches a malformed cue row here rather than the first time its state fires
-- in a playtest (docs/MOVEMENT_POLISH_ARCHITECTURE.md §1).
local KNOWN_FIELDS = {
	EnterSound = "string",
	LoopSound = "string",
	FootstepSound = "string",
	FootstepStrideStuds = "number",
	EnterParticle = "string",
	EnterParticleCount = "number",
	LoopParticle = "string",
	TargetFOV = "number",
	HoldsFOV = "boolean",
	CameraShake = "string",
	Replication = "string",
}

-- Camera.FieldOfView's valid range.
local MIN_FOV = 1
local MAX_FOV = 120

return function(t)
	local MovementCues =
		t.harness.require("ReplicatedStorage", "Shared", "Presentation", "MovementCues")
	local MovementStates = t.harness.require("ReplicatedStorage", "Shared", "FSM", "MovementStates")
	local PresentationConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "PresentationConstants")

	local stateNames = {}
	for name, state in pairs(MovementStates) do
		stateNames[state] = name
	end

	t.describe("MovementCues", function()
		t.it("is keyed only by real movement states", function()
			for state in pairs(MovementCues) do
				t.expect(stateNames[state] ~= nil).toBeTruthy()
			end
		end)

		for state, cue in pairs(MovementCues) do
			local name = stateNames[state] or tostring(state)

			t.it(`{name}: uses only known fields, with the right types`, function()
				for field, value in pairs(cue) do
					t.expect(KNOWN_FIELDS[field]).toBe(type(value))
					if type(value) == "string" then
						t.expect(#value).toBeAtLeast(1)
					end
				end
			end)

			t.it(`{name}: pairs footstep sounds with a positive stride`, function()
				t.expect(cue.FootstepSound ~= nil).toBe(cue.FootstepStrideStuds ~= nil)
				if cue.FootstepStrideStuds then
					t.expect(cue.FootstepStrideStuds > 0).toBeTruthy()
				end
			end)

			t.it(`{name}: sets an emit count only for a positive whole burst`, function()
				if cue.EnterParticleCount then
					t.expect(cue.EnterParticle ~= nil).toBeTruthy()
					t.expect(cue.EnterParticleCount >= 1).toBeTruthy()
					t.expect(cue.EnterParticleCount % 1).toBe(0)
				end
			end)

			t.it(`{name}: has a valid FOV and doesn't both set and hold it`, function()
				if cue.TargetFOV then
					t.expect(cue.TargetFOV).toBeAtLeast(MIN_FOV)
					t.expect(cue.TargetFOV).toBeAtMost(MAX_FOV)
					t.expect(cue.HoldsFOV).toBe(nil)
				end
			end)

			t.it(`{name}: names an existing shake profile`, function()
				if cue.CameraShake then
					t.expect(PresentationConstants.ShakeProfiles[cue.CameraShake] ~= nil)
						.toBeTruthy()
				end
			end)

			t.it(`{name}: replicates only something a bystander can perceive`, function()
				local replication = cue.Replication
				if replication ~= nil then
					t.expect(replication == "Local" or replication == "Nearby").toBeTruthy()
				end
				if replication == "Nearby" then
					t.expect(cue.EnterSound ~= nil or cue.EnterParticle ~= nil).toBeTruthy()
				end
			end)
		end
	end)

	t.describe("PresentationConstants", function()
		t.it("has a valid base FOV", function()
			t.expect(PresentationConstants.BaseFOV).toBeAtLeast(MIN_FOV)
			t.expect(PresentationConstants.BaseFOV).toBeAtMost(MAX_FOV)
		end)

		t.it("has positive shake profiles", function()
			for _, profile in pairs(PresentationConstants.ShakeProfiles) do
				t.expect(profile.Magnitude > 0).toBeTruthy()
				t.expect(profile.DurationSeconds > 0).toBeTruthy()
			end
		end)
	end)
end
