--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

type MovementState = MovementStates.MovementState

export type Life = {
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementTypes.MovementContext>,
	-- Destroyed when this life ends; per-life listeners go here.
	trove: Trove.Trove,
}

-- The local player's current movement life, published by the Movement
-- controller so session-long controllers (CameraController) can follow it
-- without reaching into Movement (ARCHITECTURE §2). `Current()` covers a
-- subscriber whose Init runs after the first life has already started
-- (docs/MOVEMENT_POLISH_ARCHITECTURE.md §4.0).
local current: Life? = nil
local started: LemonSignal.Signal<Life> = LemonSignal.new()

local MovementLife = {
	Started = started,
}

function MovementLife.Set(life: Life)
	current = life
	life.trove:Add(function()
		if current == life then
			current = nil
		end
	end)
	started:Fire(life)
end

function MovementLife.Current(): Life?
	return current
end

return MovementLife
