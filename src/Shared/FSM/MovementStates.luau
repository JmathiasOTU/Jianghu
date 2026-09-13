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
}

return MovementStates
