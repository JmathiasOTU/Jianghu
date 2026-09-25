--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

export type CueReplication = "Local" | "Nearby"

-- Names refer to Sounds/ParticleEmitters in the Assets/FX/Movement rig
-- template. One-shots fire when the state is entered; loops and FOV follow
-- whatever state is current (docs/MOVEMENT_POLISH_ARCHITECTURE.md §1).
export type MovementCueDefinition = {
	EnterSound: string?,
	LoopSound: string?,
	-- A set name: each step plays <set><floor material> ("FootstepConcrete"),
	-- falling back to <set> when the material has no sound of its own.
	FootstepSound: string?,
	FootstepStrideStuds: number?,

	EnterParticle: string?,
	-- nil = PresentationConstants.DefaultEmitCount
	EnterParticleCount: number?,
	LoopParticle: string?,

	-- nil = PresentationConstants.BaseFOV, unless HoldsFOV.
	TargetFOV: number?,
	-- Keep the previous state's FOV goal, so a sprint jump or a leap off a
	-- wall run doesn't dip back to base FOV mid-air.
	HoldsFOV: boolean?,
	-- PresentationConstants.ShakeProfiles key
	CameraShake: string?,
	-- PresentationConstants.FOVKickProfiles key: a one-shot punch on entry,
	-- added on top of whatever FOV goal is current.
	FOVKick: string?,

	-- nil = "Local". Only EnterSound/EnterParticle are ever broadcast.
	Replication: CueReplication?,
}

-- A state with no row is silent, at base FOV, with no shake.
--
-- Strides are the designer's previous game's step intervals (Walk 0.48 s,
-- Run 0.33 s, CrouchWalk 0.53 s) times this game's speeds; Sprint is set for
-- about 0.3 s.
local MovementCues: { [MovementState]: MovementCueDefinition } = {
	[MovementStates.Walk] = {
		FootstepSound = "Footstep",
		FootstepStrideStuds = 8.5,
	},
	[MovementStates.CrouchWalk] = {
		FootstepSound = "Footstep",
		FootstepStrideStuds = 4.75,
	},
	[MovementStates.Run] = {
		FootstepSound = "Footstep",
		FootstepStrideStuds = 9.25,
		TargetFOV = 76,
	},
	[MovementStates.Sprint] = {
		FootstepSound = "Footstep",
		FootstepStrideStuds = 12,
		TargetFOV = 82,
	},
	[MovementStates.Slide] = {
		LoopSound = "SlideScrape",
		LoopParticle = "SlideDust",
		TargetFOV = 84,
	},
	[MovementStates.Airborne] = {
		HoldsFOV = true,
	},
	[MovementStates.DoubleJump] = {
		HoldsFOV = true,
	},
	[MovementStates.SlideJump] = {
		HoldsFOV = true,
	},
	[MovementStates.Vault] = {
		EnterSound = "VaultWhoosh",
		EnterParticle = "VaultDust",
		HoldsFOV = true,
		FOVKick = "Vault",
		Replication = "Nearby",
	},
	[MovementStates.HardLanding] = {
		EnterSound = "HardLandingThud",
		EnterParticle = "HardLandingDust",
		EnterParticleCount = 24,
		CameraShake = "HardLanding",
		Replication = "Nearby",
	},
	[MovementStates.WallRun] = {
		LoopSound = "WallRunWind",
		LoopParticle = "WallRunTrail",
		TargetFOV = 88,
	},
	[MovementStates.WallLeap] = {
		EnterSound = "WallLeapBurst",
		EnterParticle = "WallLeapBurst",
		HoldsFOV = true,
		CameraShake = "WallLeap",
		Replication = "Nearby",
	},
}

return MovementCues
