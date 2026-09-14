--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local Network = require(script.Parent.Parent.Network.network)

local DebugSnapshot = require(script.Parent.Movement.DebugSnapshot)

-- F4, developer-only debug overlay (docs/MOVEMENT.md). The instance tree itself
-- is hand-built and checked in as Assets/UI/MovementDebugOverlay.model.json
-- (docs/ARCHITECTURE.md §8: GUIs are hand-built, scripts only WaitForChild into
-- existing instances) -- this controller never constructs a single UI element,
-- it only reads live state into pre-existing TextLabels and reacts to
-- pre-existing buttons.
local DebugOverlayController = {}

local TOGGLE_KEY = Enum.KeyCode.F4
local TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local TEXT_PRIMARY = Color3.fromRGB(228, 231, 234)
local TEXT_ALARM = Color3.fromRGB(217, 115, 89)

local function formatState(state: string?): string
	return state or "—"
end

local function formatBool(value: boolean?): string
	if value == nil then
		return "—"
	end
	return if value then "true" else "false"
end

local function formatDuration(duration: number?): string
	if not duration then
		return "—"
	end
	return string.format("%.2fs", duration)
end

local function formatSpeed(speed: number?): string
	if not speed then
		return "—"
	end
	return string.format("%.1f studs/s", speed)
end

type FadeTarget = { instance: Instance, property: string, visibleValue: number }

-- Per-element transparency tweening, not a single `CanvasGroup.GroupTransparency`
-- (tried first, reverted 2026-09-14): CanvasGroup composites its whole subtree
-- into one cached texture, and it didn't reliably re-render that texture against
-- this panel's own Heartbeat-driven `TextLabel.Text` updates -- correct content
-- for a frame or two, then blank. A plain `Frame` doesn't have that failure mode
-- at all, and interpolating each element's own `BackgroundTransparency`/
-- `TextTransparency`/`UIStroke.Transparency` directly gets the same visual
-- crossfade without ever compositing anything.
local function collectFadeTargets(root: Instance): { FadeTarget }
	local targets: { FadeTarget } = {}

	local function capture(instance: Instance, property: string)
		table.insert(
			targets,
			{ instance = instance, property = property, visibleValue = (instance :: any)[property] }
		)
	end

	capture(root, "BackgroundTransparency")
	for _, descendant in root:GetDescendants() do
		if
			descendant:IsA("Frame")
			or descendant:IsA("TextButton")
			or descendant:IsA("TextLabel")
			or descendant:IsA("TextBox")
		then
			capture(descendant, "BackgroundTransparency")
		end
		if
			descendant:IsA("TextLabel")
			or descendant:IsA("TextButton")
			or descendant:IsA("TextBox")
		then
			capture(descendant, "TextTransparency")
		end
		if descendant:IsA("UIStroke") then
			capture(descendant, "Transparency")
		end
	end

	return targets
end

function DebugOverlayController.Init()
	local player = Players.LocalPlayer

	local playerGui = player:WaitForChild("PlayerGui")
	local screenGui = playerGui:WaitForChild("MovementDebugOverlay") :: ScreenGui

	-- Developer-only, enforced here too (not just server-side) so a normal
	-- player's client never wires up input handling or shows the corner tab at
	-- all -- the ACTUAL security boundary is still RequestDevTeleport's
	-- server-side check (DevToolsService.luau), this is just so the overlay isn't
	-- visible clutter for everyone. Same `DeveloperAllowlist.IsDeveloper` check as
	-- the server, so the two can never disagree about who counts as a developer.
	if not DeveloperAllowlist.IsDeveloper(player) then
		screenGui.Enabled = false
		return
	end

	local cornerTab = screenGui:WaitForChild("CornerTab") :: TextButton
	local panel = screenGui:WaitForChild("Panel") :: Frame

	local titleRow = panel:WaitForChild("TitleRow")
	local closeButton = titleRow:WaitForChild("CloseButton") :: TextButton

	local clientSection = panel:WaitForChild("ClientSection")
	local clientStateValue =
		clientSection:WaitForChild("RowState"):WaitForChild("Value") :: TextLabel
	local clientGroundedValue =
		clientSection:WaitForChild("RowGrounded"):WaitForChild("Value") :: TextLabel
	local clientRunDurationValue =
		clientSection:WaitForChild("RowRunDuration"):WaitForChild("Value") :: TextLabel
	local clientSpeedValue =
		clientSection:WaitForChild("RowSpeed"):WaitForChild("Value") :: TextLabel

	local serverSection = panel:WaitForChild("ServerSection")
	local serverStateValue =
		serverSection:WaitForChild("RowState"):WaitForChild("Value") :: TextLabel
	local serverRunDurationValue =
		serverSection:WaitForChild("RowRunDuration"):WaitForChild("Value") :: TextLabel
	local serverViolationsValue =
		serverSection:WaitForChild("RowViolations"):WaitForChild("Value") :: TextLabel
	local mismatchFlag = serverSection:WaitForChild("MismatchFlag") :: TextLabel

	local teleportSection = panel:WaitForChild("TeleportSection")
	local coordRow = teleportSection:WaitForChild("CoordRow")
	local xBox = coordRow:WaitForChild("X") :: TextBox
	local yBox = coordRow:WaitForChild("Y") :: TextBox
	local zBox = coordRow:WaitForChild("Z") :: TextBox
	local buttonRow = teleportSection:WaitForChild("ButtonRow")
	local goButton = buttonRow:WaitForChild("GoButton") :: TextButton
	local pickButton = buttonRow:WaitForChild("PickButton") :: TextButton
	local statusLabel = teleportSection:WaitForChild("Status") :: TextLabel

	local trove = Trove.new()

	-- Latest broadcast from MovementValidationService, or nil until the first one
	-- arrives (docs/MOVEMENT.md: one-way server -> owning-client broadcast).
	local serverState: {
		state: Network.DebugMovementState,
		runDuration: number?,
		violationCount: number,
	}? =
		nil

	local isOpen = false
	local fadeTargets: { FadeTarget }? = nil

	local function playFade(open: boolean)
		if not fadeTargets then
			fadeTargets = collectFadeTargets(panel)
			print(string.format("[DebugOverlay] collectFadeTargets found %d targets", #fadeTargets))
		end
		local targets = fadeTargets :: { FadeTarget }
		print(string.format("[DebugOverlay] playFade(%s) -- %d targets", tostring(open), #targets))

		if open then
			-- Snap every element fully transparent the instant `panel.Visible`
			-- flips true, so the fade-in tween below has something to fade FROM --
			-- otherwise the panel would flash its fully-opaque baked-in look for one
			-- frame before the tween catches up.
			for _, target in targets do
				(target.instance :: any)[target.property] = 1
			end
		end

		for _, target in targets do
			local goal = if open then target.visibleValue else 1
			TweenService:Create(target.instance :: Instance, TWEEN_INFO, {
				[target.property] = goal,
			}):Play()
		end
	end

	local function setOpen(open: boolean)
		-- TEMPORARY diagnostic (docs/MOVEMENT.md) -- remove once the repeated-close
		-- bug is actually found. Prints every call so we can see exactly how many
		-- times this fires, and from what isOpen state, on a single F4 press.
		print(
			string.format(
				"[DebugOverlay] setOpen(%s) -- isOpen was %s",
				tostring(open),
				tostring(isOpen)
			)
		)

		if open == isOpen then
			print("[DebugOverlay] setOpen: no-op, already in that state")
			return
		end
		isOpen = open

		if open then
			cornerTab.Visible = false
			panel.Visible = true
			playFade(true)
		else
			cornerTab.Visible = true
			playFade(false)
			task.delay(TWEEN_INFO.Time, function()
				if not isOpen then
					panel.Visible = false
				end
			end)
		end
	end

	-- Debounced on the key itself, not just on `isOpen` (found 2026-09-14): a
	-- held F4 can fire a second `InputBegan` for the same physical press via OS
	-- key-repeat, which toggled the panel open then immediately closed again a
	-- fraction of a second later -- looked identical to a rendering bug ("flashes
	-- correct, then blank") across every animation technique tried, because the
	-- panel really was being asked to close every time, no matter how it opened.
	local f4Held = false

	trove:Connect(
		UserInputService.InputBegan,
		function(input: InputObject, gameProcessedEvent: boolean)
			if input.KeyCode == TOGGLE_KEY then
				print(
					string.format(
						"[DebugOverlay] F4 InputBegan -- gameProcessedEvent=%s f4Held=%s UserInputState=%s",
						tostring(gameProcessedEvent),
						tostring(f4Held),
						tostring(input.UserInputState)
					)
				)
			end
			if gameProcessedEvent then
				return
			end
			if input.KeyCode == TOGGLE_KEY and not f4Held then
				f4Held = true
				setOpen(not isOpen)
			end
		end
	)

	trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if input.KeyCode == TOGGLE_KEY then
			print("[DebugOverlay] F4 InputEnded")
			f4Held = false
		end
	end)

	trove:Connect(cornerTab.MouseButton1Click, function()
		setOpen(true)
	end)

	trove:Connect(closeButton.MouseButton1Click, function()
		setOpen(false)
	end)

	-- SetCallback returns a plain disconnector function, not an RBXScriptSignal --
	-- Trove:Add (not Trove:Connect) is what treats a bare function as a cleanup
	-- task to run on Destroy.
	trove:Add(Network.MovementDebugState.SetCallback(function(value)
		serverState = value
	end))

	-- Only updates the readout while the panel is actually visible -- cheap
	-- either way, but there's no reason to touch a dozen TextLabels a frame for a
	-- panel nobody's looking at.
	trove:Connect(RunService.Heartbeat, function()
		if not isOpen then
			return
		end

		local client = DebugSnapshot.Get()
		clientStateValue.Text = formatState(client.state)
		clientGroundedValue.Text = formatBool(client.grounded)
		clientRunDurationValue.Text = formatDuration(client.runDuration)
		clientSpeedValue.Text = formatSpeed(client.speed)

		if serverState then
			serverRunDurationValue.Text = formatDuration(serverState.runDuration)
			serverViolationsValue.Text = tostring(serverState.violationCount)
			serverViolationsValue.TextColor3 = if serverState.violationCount > 0
				then TEXT_ALARM
				else TEXT_PRIMARY

			local mismatched = serverState.state ~= client.state
			serverStateValue.Text = formatState(serverState.state)
			serverStateValue.TextColor3 = if mismatched then TEXT_ALARM else TEXT_PRIMARY
			mismatchFlag.Visible = mismatched
		else
			serverStateValue.Text = "—"
			serverRunDurationValue.Text = "—"
			serverViolationsValue.Text = "—"
			mismatchFlag.Visible = false
		end
	end)

	-- Teleport tool -----------------------------------------------------------

	local function teleportTo(position: Vector3)
		Network.RequestDevTeleport.Fire(vector.create(position.X, position.Y, position.Z))
		statusLabel.Text =
			string.format("Teleported to %.1f, %.1f, %.1f", position.X, position.Y, position.Z)
	end

	trove:Connect(goButton.MouseButton1Click, function()
		local x = tonumber(xBox.Text) or 0
		local y = tonumber(yBox.Text) or 0
		local z = tonumber(zBox.Text) or 0
		teleportTo(Vector3.new(x, y, z))
	end)

	local picking = false
	local pickConnection: RBXScriptConnection? = nil

	-- Uses trove:Remove (disconnects AND untracks in one call), not a bare
	-- :Disconnect(), so starting/stopping picking many times across a session
	-- doesn't leave a growing pile of already-dead entries in the trove's list --
	-- each pick's connection is added via trove:Connect below and fully forgotten
	-- here once it's done its one job.
	local function stopPicking()
		picking = false
		pickButton.Text = "Pick Point In World"
		if pickConnection then
			trove:Remove(pickConnection)
			pickConnection = nil
		end
	end

	trove:Connect(pickButton.MouseButton1Click, function()
		if picking then
			stopPicking()
			statusLabel.Text = "Pick cancelled."
			return
		end

		picking = true
		pickButton.Text = "Click anywhere…"
		statusLabel.Text = "Click anywhere in the world to teleport there."

		pickConnection = trove:Connect(
			UserInputService.InputBegan,
			function(input: InputObject, gameProcessedEvent: boolean)
				if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
					return
				end
				stopPicking()
				if gameProcessedEvent then
					-- Clicked a GUI element (e.g. the pick button itself finishing its
					-- own click) rather than the world -- don't fire a bogus teleport.
					return
				end

				local camera = Workspace.CurrentCamera
				if not camera then
					return
				end

				local mousePosition = UserInputService:GetMouseLocation()
				local unitRay = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)

				local filterInstances: { Instance } = {}
				if player.Character then
					table.insert(filterInstances, player.Character)
				end

				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = filterInstances

				local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 1000, params)
				if not result then
					statusLabel.Text = "Pick missed -- no part hit."
					return
				end

				local destination = result.Position + Vector3.new(0, 3, 0)
				xBox.Text = string.format("%.1f", destination.X)
				yBox.Text = string.format("%.1f", destination.Y)
				zBox.Text = string.format("%.1f", destination.Z)
				teleportTo(destination)
			end
		)
	end)
end

return DebugOverlayController
