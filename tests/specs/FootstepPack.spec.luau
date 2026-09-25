--!strict
-- The footstep pack and its material aliases are maintained separately, so a
-- renamed clip or a stale alias would only show up as silent steps in a
-- playtest (docs/MOVEMENT_POLISH_ARCHITECTURE.md §3.2).
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local PACK_PATH = "Assets/FX/Footsteps.model.json"
local FOOT_ATTACHMENTS = {
	{ "Left Leg", "LeftFootAttachment" },
	{ "Right Leg", "RightFootAttachment" },
}

local function isMaterial(name: string): boolean
	return (pcall(function()
		return (roblox.Enum.Material :: any)[name]
	end))
end

return function(t: any)
	local PresentationConstants =
		t.harness.require("ReplicatedStorage", "Shared", "Constants", "PresentationConstants")

	local pack = serde.decode("json", fs.readFile(PACK_PATH))
	local project = serde.decode("json", fs.readFile("default.project.json"))
	local soundNames: { [string]: boolean } = {}
	for _, child in ipairs(pack.Children) do
		soundNames[child.Name] = true
	end

	t.describe("Footstep pack", function()
		t.it("is only Sounds with a SoundId, each named after a floor material", function()
			for _, child in ipairs(pack.Children) do
				t.expect(child.ClassName).toBe("Sound")
				t.expect(type(child.Properties.SoundId)).toBe("string")
				t.expect(isMaterial(child.Name)).toBe(true)
			end
		end)

		t.it("has the default material's sound", function()
			t.expect(soundNames[PresentationConstants.FootstepDefaultMaterial]).toBe(true)
		end)

		t.it("aliases only real, uncovered materials onto sounds it has", function()
			for material, alias in pairs(PresentationConstants.FootstepMaterialAliases) do
				t.expect(isMaterial(material)).toBe(true)
				t.expect(soundNames[material]).toBe(nil)
				t.expect(soundNames[alias]).toBe(true)
			end
		end)

		t.it("names a SoundGroup that exists in SoundService", function()
			local group = pack.attributes.SoundGroup
			t.expect(type(group)).toBe("string")
			t.expect(project.tree.SoundService[group] ~= nil).toBeTruthy()
		end)

		-- Steps alternate feet, so each clip has two strides to finish.
		t.it("is mounted as Footstep on both feet", function()
			local movement = project.tree.ReplicatedStorage.Assets.FX.Movement
			for _, path in ipairs(FOOT_ATTACHMENTS) do
				local node = movement[path[1]][path[2]].Footstep
				t.expect(node and node["$path"]).toBe(PACK_PATH)
			end
		end)
	end)
end
