--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)
local Trove = require(ReplicatedStorage.Packages.Trove)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local TuningSnapshot = require(script.Parent.TuningSnapshot)

type MoveIntent = MovementTypes.MoveIntent

export type InputController = {
	RunRequested: LemonSignal.Signal<()>,
	-- Fires the toggled crouch state (docs/MOVEMENT.md §9) -- `true`/`false`
	-- each time Ctrl is PRESSED, alternating; release does nothing. Distinct
	-- from `RunRequested`'s "()" shape since Crouch's claim needs to know
	-- which state it just toggled INTO, not just that Ctrl was pressed.
	CrouchChanged: LemonSignal.Signal<boolean>,
	-- Fires once per PHYSICAL press of the jump key, grounded or not
	-- (TRAVERSAL-ROADMAP.md §4, Phase 1) -- deliberately NOT
	-- `Humanoid.Jumping`/`GetState()`: Roblox's own ground controller only
	-- ever re-enters the `Jumping` state from a grounded takeoff, so a second
	-- press while already airborne produces no Humanoid state change at all
	-- to observe. This is what DoubleJump's entry needs to react to.
	--
	-- Edge-tracked off raw `Space` `InputBegan`/`InputEnded` (same pattern as
	-- `LeftControl` below), NOT `UserInputService.JumpRequest` -- that engine
	-- event is documented to fire repeatedly for a single held press (a
	-- long-standing Roblox engine quirk, see devforum "JumpRequest fires
	-- rapidly"), not just once on press. Wiring DoubleJump's entry straight to
	-- it meant a single space-bar tap -- which spans several frames -- could
	-- refire `JumpRequest` again right after the character left the ground,
	-- while the FSM had already advanced to `Airborne`, instantly consuming
	-- the double jump with no separate second press. Tracking the key edge
	-- ourselves fires exactly once per physical press-release cycle.
	JumpRequested: LemonSignal.Signal<()>,
	-- WallBoost's own input (docs/WallClimbingPlan.md §2/§10.1 step 5): fires
	-- once per physical F press. A plain InputBegan edge is enough here --
	-- unlike Space's own JumpRequested, there's no `UserInputService`-level
	-- engine quirk to guard against (JumpRequested's own doc comment explains
	-- why that one specifically can't be a raw passthrough).
	BoostRequested: LemonSignal.Signal<()>,
	GetMoveIntent: (self: InputController) -> MoveIntent,
	IsCrouchHeld: (self: InputController) -> boolean,
	ReleaseHeldKeys: (self: InputController) -> (),
	Reset: (self: InputController) -> (),
	Destroy: (self: InputController) -> (),
}

local InputController = {}
InputController.__index = InputController

type Axis = "forward" | "backward" | "strafeLeft" | "strafeRight"

local KEY_TO_AXIS: { [Enum.KeyCode]: Axis } = {
	[Enum.KeyCode.W] = "forward",
	[Enum.KeyCode.S] = "backward",
	[Enum.KeyCode.A] = "strafeLeft",
	[Enum.KeyCode.D] = "strafeRight",
}

local function setAxis(self: any, axis: Axis, held: boolean)
	if axis == "forward" then
		self._forward = held
	elseif axis == "backward" then
		self._backward = held
	elseif axis == "strafeLeft" then
		self._strafeLeft = held
	else
		self._strafeRight = held
	end
end

-- Keyboard only, by design decision (2026-09-24, audit M-013): gamepad and
-- touch players still move through Roblox's default controls at Walk speed
-- (the client FSM stays in Idle, which sets the same WalkSpeed the server's
-- MoveDirection-derived Walk caps at, so nothing desyncs or gets flagged), but
-- Run/Sprint/Crouch/Slide/wall moves/Boost are keyboard-only until this layer
-- grows action-based bindings.
--
-- Raw input -> Intent, per docs/MOVEMENT.md §1. Owns the W double-tap-to-Run
-- detector (the only discrete gesture in Phase 1's input set) and resolves the held
-- WASD axes into a camera-relative world-space direction every frame; the FSM/state
-- layer never touches UserInputService directly.
function InputController.new(): InputController
	local self = setmetatable({}, InputController) :: any
	self._trove = Trove.new()
	self.RunRequested = self._trove:Add(LemonSignal.new(), "Destroy")
	self.CrouchChanged = self._trove:Add(LemonSignal.new(), "Destroy")
	self.JumpRequested = self._trove:Add(LemonSignal.new(), "Destroy")
	self.BoostRequested = self._trove:Add(LemonSignal.new(), "Destroy")

	self._forward = false
	self._backward = false
	self._strafeLeft = false
	self._strafeRight = false
	self._lastWPressAt = nil :: number?
	self._crouchHeld = false
	self._jumpHeld = false

	self._trove:Connect(
		UserInputService.InputBegan,
		function(input: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent then
				return
			end

			if input.KeyCode == Enum.KeyCode.LeftControl then
				self._crouchHeld = not self._crouchHeld
				self.CrouchChanged:Fire(self._crouchHeld)
				return
			end

			-- Edge-triggered, not a raw `JumpRequest` passthrough -- see
			-- `JumpRequested`'s doc comment above for why. `_jumpHeld` guards
			-- against a stray double-fire of `InputBegan` itself; the actual
			-- debounce this exists for is the `InputEnded` pairing below.
			if input.KeyCode == Enum.KeyCode.Space then
				if self._jumpHeld then
					return
				end
				self._jumpHeld = true
				self.JumpRequested:Fire()
				return
			end

			if input.KeyCode == Enum.KeyCode.F then
				self.BoostRequested:Fire()
				return
			end

			local axis = KEY_TO_AXIS[input.KeyCode]
			if not axis then
				return
			end
			setAxis(self, axis, true)

			if input.KeyCode == Enum.KeyCode.W then
				local now = os.clock()
				if
					self._lastWPressAt
					and now - self._lastWPressAt
						<= TuningSnapshot.Get().RunDoubleTapWindowSeconds
				then
					self.RunRequested:Fire()
					self._lastWPressAt = nil
				else
					self._lastWPressAt = now
				end
			end
		end
	)

	self._trove:Connect(
		UserInputService.InputEnded,
		function(input: InputObject, _gameProcessedEvent: boolean)
			-- LeftControl release is deliberately ignored -- crouch is a toggle
			-- (press to enter, press again to leave), not a hold, so only
			-- InputBegan above ever touches `_crouchHeld`.
			if input.KeyCode == Enum.KeyCode.Space then
				self._jumpHeld = false
				return
			end

			local axis = KEY_TO_AXIS[input.KeyCode]
			if not axis then
				return
			end
			setAxis(self, axis, false)
		end
	)

	-- Neither alt-tab nor a TextBox grabbing focus mid-press delivers the
	-- matching InputEnded (audit M-012), which left WASD latched and
	-- `_jumpHeld` stuck true -- silently swallowing every later Space press.
	self._trove:Connect(UserInputService.WindowFocusReleased, function()
		self:ReleaseHeldKeys()
	end)
	self._trove:Connect(UserInputService.TextBoxFocused, function()
		self:ReleaseHeldKeys()
	end)

	return self
end

-- Held keys only -- crouch is a toggle, not a hold, so losing focus leaves it
-- exactly as the player last set it.
function InputController:ReleaseHeldKeys()
	self._forward = false
	self._backward = false
	self._strafeLeft = false
	self._strafeRight = false
	self._jumpHeld = false
	self._lastWPressAt = nil
end

-- Called at the start of every character life: this controller outlives the
-- character, so without this a crouch toggled on in the previous life leaked
-- into a fresh server session that starts un-crouched (audit M-012).
function InputController:Reset()
	self:ReleaseHeldKeys()
	self._crouchHeld = false
end

function InputController:GetMoveIntent(): MoveIntent
	local forward = self._forward
	local backward = self._backward
	local strafeLeft = self._strafeLeft
	local strafeRight = self._strafeRight

	local axisX = (strafeRight and 1 or 0) - (strafeLeft and 1 or 0)
	local axisZ = (backward and 1 or 0) - (forward and 1 or 0)

	local direction = Vector3.zero
	local camera = Workspace.CurrentCamera
	if camera and (axisX ~= 0 or axisZ ~= 0) then
		local cameraCFrame = camera.CFrame
		local camForward = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		local camRight = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		if camForward.Magnitude > 0 and camRight.Magnitude > 0 then
			local resolved = camRight.Unit * axisX - camForward.Unit * axisZ
			if resolved.Magnitude > 0 then
				direction = resolved.Unit
			end
		end
	end

	return {
		direction = direction,
		forward = forward,
		backward = backward,
		strafeLeft = strafeLeft,
		strafeRight = strafeRight,
	}
end

function InputController:IsCrouchHeld(): boolean
	return self._crouchHeld
end

function InputController:Destroy()
	self._trove:Destroy()
end

return InputController
