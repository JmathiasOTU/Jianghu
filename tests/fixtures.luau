--!strict
-- A complete, neutral MovementContext (grounded, idle, no input, shipped
-- tuning) that each test overrides only the fields it cares about.
local roblox = require("@lune/roblox")
local harness = require("./harness")

local MovementTuning = harness.require("ReplicatedStorage", "Shared", "Movement", "MovementTuning")

local Vector3 = roblox.Vector3

local Fixtures = {}

function Fixtures.moveIntent(overrides: { [string]: any }?): any
	local intent = {
		direction = Vector3.zero,
		forward = false,
		backward = false,
		strafeLeft = false,
		strafeRight = false,
	}
	for key, value in pairs(overrides or {}) do
		intent[key] = value
	end
	return intent
end

function Fixtures.context(overrides: { [string]: any }?): any
	local context = {
		moveIntent = Fixtures.moveIntent(),
		grounded = true,
		jumping = false,
		crouchHeld = false,
		doubleJumpUsed = false,
		runDuration = nil,
		preAirborneLocomotion = nil,
		fallHeight = nil,
		horizontalVelocity = Vector3.zero,
		wallRunQuery = nil,
		wallClingQuery = nil,
		facingDirection = Vector3.new(0, 0, -1),
		wallClingLockoutUntil = nil,
		wallClingBoostUsed = false,
		lastWallLeapWall = nil,
		qinggong = math.huge,
		cameraLocked = false,
		constants = MovementTuning.Defaults(),
	}
	for key, value in pairs(overrides or {}) do
		context[key] = value
	end
	return context
end

-- A stand-in wall part: the rules only ever compare instances by identity.
function Fixtures.wall(name: string): any
	return { Name = name }
end

return Fixtures
