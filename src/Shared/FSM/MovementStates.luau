--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Symbol = require(ReplicatedStorage.Packages.Symbol)

export type MovementState = typeof(Symbol())

local MovementStates: { [string]: MovementState } = {
	Idle = Symbol("Idle"),
	Walk = Symbol("Walk"),
	Run = Symbol("Run"),
	Sprint = Symbol("Sprint"),
	Airborne = Symbol("Airborne"),
	CrouchIdle = Symbol("CrouchIdle"),
	CrouchWalk = Symbol("CrouchWalk"),
	Slide = Symbol("Slide"),
	SlideJump = Symbol("SlideJump"),
	DoubleJump = Symbol("DoubleJump"),
	HardLanding = Symbol("HardLanding"),
}

return MovementStates
