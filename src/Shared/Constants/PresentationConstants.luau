--!strict

export type ShakeProfile = {
	-- Peak positional offset, studs.
	Magnitude: number,
	DurationSeconds: number,
}

export type FOVKickProfile = {
	-- Degrees added to the FOV at once, easing back to zero.
	Amount: number,
	DurationSeconds: number,
}

-- Visual polish numbers (docs/MOVEMENT_POLISH_ARCHITECTURE.md §6). Cosmetic
-- only and never validated server-side, so none of these are in the F4
-- live-tuning set. Every value is a starting point, not yet tuned in a
-- playtest.
local ShakeProfiles: { [string]: ShakeProfile } = {
	HardLanding = { Magnitude = 0.6, DurationSeconds = 0.35 },
	WallLeap = { Magnitude = 0.25, DurationSeconds = 0.2 },
}

-- One-shot FOV punches on top of the state's FOV goal (§4.2). Sorcery's vault
-- kicks +20 and tweens back over 0.5 s (docs/VaultMechanic.md §1.3); smaller
-- here because our FOV is already raised while sprinting or wall running.
local FOVKickProfiles: { [string]: FOVKickProfile } = {
	Vault = { Amount = 10, DurationSeconds = 0.5 },
}

local PresentationConstants = {
	-- The same one-shot cue replayed sooner than this is skipped, on the
	-- client and in the server's Nearby broadcast.
	MinCueRetriggerSeconds = 0.15,
	-- Particles emitted by an EnterParticle whose cue row sets no count.
	DefaultEmitCount = 16,

	-- Attributes shared by the server's FX mount and the client's FX index (§2).
	-- CueAttribute marks every mounted Sound/ParticleEmitter, so the index never
	-- picks up the character's other sounds; SoundGroupAttribute names the
	-- SoundService group a template Sound belongs to.
	CueAttribute = "MovementCue",
	SoundGroupAttribute = "SoundGroup",
	MountedAttribute = "MovementFXMounted",

	-- +/- fraction applied to each footstep's PlaybackSpeed.
	FootstepPitchJitter = 0.1,
	-- The footstep pack has one clip per surface category (Plastic, Grass,
	-- Metal, Wood, Concrete, Fabric, Sand, Glass); every other floor material
	-- maps to one of them. Carried over from the designer's previous game,
	-- plus Plaster/Cardboard/Carpet/Leather/roof and ceramic tiles, which it
	-- left on the default. Anything unlisted falls back to the default.
	FootstepMaterialAliases = {
		SmoothPlastic = "Plastic",
		ForceField = "Plastic",
		Foil = "Plastic",
		WoodPlanks = "Wood",
		Ground = "Fabric",
		Cardboard = "Fabric",
		Carpet = "Fabric",
		Leather = "Fabric",
		DiamondPlate = "Metal",
		CorrodedMetal = "Metal",
		LeafyGrass = "Grass",
		Mud = "Grass",
		Snow = "Grass",
		Glacier = "Grass",
		Pavement = "Concrete",
		Limestone = "Concrete",
		Salt = "Concrete",
		Asphalt = "Concrete",
		Neon = "Concrete",
		CrackedLava = "Concrete",
		Basalt = "Concrete",
		Sandstone = "Concrete",
		Rock = "Concrete",
		Cobblestone = "Concrete",
		Pebble = "Concrete",
		Brick = "Concrete",
		Granite = "Concrete",
		Marble = "Concrete",
		Ice = "Concrete",
		Slate = "Concrete",
		Plaster = "Concrete",
		ClayRoofTiles = "Concrete",
		RoofShingles = "Concrete",
		CeramicTiles = "Concrete",
	} :: { [string]: string },
	FootstepDefaultMaterial = "Plastic",
	-- Applied to every Sound a Nearby cue plays; Roblox's default reaches
	-- across the whole map.
	NearbyRollOffMaxDistance = 80,

	BaseFOV = 70,
	FOVDampingRatio = 1,
	FOVFrequency = 3,

	ShakeProfiles = ShakeProfiles,
	FOVKickProfiles = FOVKickProfiles,

	-- Shift lock (§4.3). Springs carried over from the designer's reference
	-- implementation: its spring "Speed" is in rad/s, ours is Hz. Offset pulled
	-- in from the reference's 1.75 (read as too far right in playtest).
	ShiftLockOffset = Vector3.new(1, 0.25, 0),
	ShiftLockDampingRatio = 0.7,
	ShiftLockInFrequency = 10 / (2 * math.pi),
	ShiftLockOutFrequency = 14 / (2 * math.pi),
	ShiftLockMouseIcon = "rbxasset://textures/MouseLockedCursor.png",
	-- The camera counts as first person (no shoulder offset) once the head
	-- fades past this or the camera is this close to it.
	FirstPersonHeadTransparency = 0.6,
	FirstPersonHeadDistance = 1,
}

return PresentationConstants
