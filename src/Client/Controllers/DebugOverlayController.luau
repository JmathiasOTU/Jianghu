--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Trove = require(ReplicatedStorage.Packages.Trove)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local Network = require(script.Parent.Parent.Network.network)

local DebugSnapshot = require(script.Parent.Movement.DebugSnapshot)
local TuningSnapshot = require(script.Parent.Movement.TuningSnapshot)

type TunableConstantName = MovementTuning.TunableConstantName

-- F4, developer-only debug overlay (docs/MOVEMENT.md). The instance tree itself
-- is hand-built and checked in as Assets/UI/MovementDebugOverlay.model.json
-- (docs/ARCHITECTURE.md §8: GUIs are hand-built, scripts only WaitForChild into
-- existing instances) -- this controller never constructs a single UI element,
-- it only reads live state into pre-existing TextLabels and reacts to
-- pre-existing buttons. Bounded-history lists (state transitions, network
-- claims, violations, waypoints -- docs/MOVEMENT.md §8) are the same pattern
-- applied to a list: a fixed-size pool of pre-built rows the controller shows/
-- hides and re-labels, never a `:Clone()`/`Instance.new()` runtime-built row.
local DebugOverlayController = {}

local TOGGLE_KEY = Enum.KeyCode.F4
local TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local TEXT_PRIMARY = Color3.fromRGB(228, 231, 234)
local TEXT_ALARM = Color3.fromRGB(217, 115, 89)
local TEXT_MUTED = Color3.fromRGB(138, 143, 152)
local ACCENT = Color3.fromRGB(89, 173, 191)
local BG_DARK = Color3.fromRGB(13, 14, 18)

-- Session-only (docs/MOVEMENT.md §8) -- deliberately not ProfileStore-backed,
-- same "no reason to touch persistence for this" reasoning as the panel's own
-- dragged position below. Capped at a fixed number so the row pool in
-- MovementDebugOverlay.model.json (WaypointsSection.List.Row1..Row8) can stay a
-- pre-built pool rather than an unbounded runtime-constructed list.
type Waypoint = { name: string, position: Vector3 }
local WAYPOINT_LIMIT = 8

-- Mirrors network.zap's RequestMovementTransition claim window loosely -- not a
-- protocol timeout, just "how long before an unreflected claim in the overlay's
-- own log is shown as likely-rejected rather than still-pending" (docs/MOVEMENT.md
-- §8). Comfortably above CLAIM_RESYNC_INTERVAL_SECONDS (Movement/init.luau) so a
-- claim that's merely waiting for its next periodic resend isn't flagged early.
local CLAIM_REFLECT_TIMEOUT_SECONDS = 2

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

local function formatVector(vector3: Vector3?): string
	if not vector3 then
		return "—"
	end
	return string.format("%.1f, %.1f, %.1f", vector3.X, vector3.Y, vector3.Z)
end

local function formatAgo(seconds: number): string
	return string.format("%.1fs ago", seconds)
end

type FadeTarget = { instance: Instance, property: string, visibleValue: number }

-- Per-element transparency tweening, not a single `CanvasGroup.GroupTransparency`
-- (tried first, reverted 2026-09-14): CanvasGroup composites its whole subtree
-- into one cached texture, and it didn't reliably re-render that texture against
-- this panel's own Heartbeat-driven `TextLabel.Text` updates -- correct content
-- for a frame or two, then blank. A plain `Frame` doesn't have that failure mode
-- at all, and interpolating each element's own `BackgroundTransparency`/
-- `TextTransparency`/`UIStroke.Transparency` directly gets the same visual
-- crossfade without ever compositing anything. Kept as-is through the §8 panel
-- restructuring (tabs/drag) -- nothing about tabbing changes which elements need
-- fading, `collectFadeTargets` already walks every descendant regardless of which
-- tab currently has `Visible = true`.
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
			or descendant:IsA("ScrollingFrame")
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
	-- all -- the ACTUAL security boundary is still every dev-only remote's
	-- server-side check (DevToolsService.RegisterDevOnly, docs/MOVEMENT.md §8),
	-- this is just so the overlay isn't visible clutter for everyone. Same
	-- `DeveloperAllowlist.IsDeveloper` check as the server, so the two can never
	-- disagree about who counts as a developer.
	if not DeveloperAllowlist.IsDeveloper(player) then
		screenGui.Enabled = false
		return
	end

	local cornerTab = screenGui:WaitForChild("CornerTab") :: TextButton
	local panel = screenGui:WaitForChild("Panel") :: Frame

	local titleRow = panel:WaitForChild("TitleRow") :: Frame
	local closeButton = titleRow:WaitForChild("CloseButton") :: TextButton

	local tabBar = panel:WaitForChild("TabBar")
	local movementTabButton = tabBar:WaitForChild("MovementTabButton") :: TextButton
	local worldTabButton = tabBar:WaitForChild("WorldTabButton") :: TextButton
	local tuningTabButton = tabBar:WaitForChild("TuningTabButton") :: TextButton

	local tabContent = panel:WaitForChild("TabContent")
	local movementTab = tabContent:WaitForChild("MovementTab") :: Frame
	local worldTab = tabContent:WaitForChild("WorldTab") :: Frame
	local tuningTab = tabContent:WaitForChild("TuningTab") :: Frame

	local clientSection = movementTab:WaitForChild("ClientSection")
	local clientStateValue = clientSection:WaitForChild("RowState"):WaitForChild("Value") :: TextLabel
	local clientGroundedValue = clientSection:WaitForChild("RowGrounded"):WaitForChild("Value") :: TextLabel
	local clientRunDurationValue =
		clientSection:WaitForChild("RowRunDuration"):WaitForChild("Value") :: TextLabel
	local clientSpeedValue = clientSection:WaitForChild("RowSpeed"):WaitForChild("Value") :: TextLabel
	local clientVelocityValue = clientSection:WaitForChild("RowVelocity"):WaitForChild("Value") :: TextLabel
	local clientRotVelocityValue =
		clientSection:WaitForChild("RowRotVelocity"):WaitForChild("Value") :: TextLabel

	local stateHistoryList = movementTab:WaitForChild("StateHistorySection"):WaitForChild("List")
	local stateHistoryRows: { TextLabel } = {}
	for i = 1, 10 do
		stateHistoryRows[i] = stateHistoryList:WaitForChild("Row" .. i) :: TextLabel
	end

	local serverSection = movementTab:WaitForChild("ServerSection")
	local serverStateValue = serverSection:WaitForChild("RowState"):WaitForChild("Value") :: TextLabel
	local serverRunDurationValue =
		serverSection:WaitForChild("RowRunDuration"):WaitForChild("Value") :: TextLabel
	local serverViolationsValue =
		serverSection:WaitForChild("RowViolations"):WaitForChild("Value") :: TextLabel
	local mismatchFlag = serverSection:WaitForChild("MismatchFlag") :: TextLabel

	local violationHistoryList = movementTab:WaitForChild("ViolationHistorySection"):WaitForChild("List")
	local violationHistoryRows: { TextLabel } = {}
	for i = 1, 5 do
		violationHistoryRows[i] = violationHistoryList:WaitForChild("Row" .. i) :: TextLabel
	end

	local claimLogList = movementTab:WaitForChild("ClaimLogSection"):WaitForChild("List")
	local claimLogRows: { TextLabel } = {}
	for i = 1, 8 do
		claimLogRows[i] = claimLogList:WaitForChild("Row" .. i) :: TextLabel
	end

	local teleportSection = worldTab:WaitForChild("TeleportSection")
	local coordRow = teleportSection:WaitForChild("CoordRow")
	local xBox = coordRow:WaitForChild("X") :: TextBox
	local yBox = coordRow:WaitForChild("Y") :: TextBox
	local zBox = coordRow:WaitForChild("Z") :: TextBox
	local buttonRow = teleportSection:WaitForChild("ButtonRow")
	local goButton = buttonRow:WaitForChild("GoButton") :: TextButton
	local pickButton = buttonRow:WaitForChild("PickButton") :: TextButton
	local teleportStatusLabel = teleportSection:WaitForChild("Status") :: TextLabel

	local noclipSection = worldTab:WaitForChild("NoclipSection")
	local noclipToggleButton = noclipSection:WaitForChild("ToggleRow"):WaitForChild("ToggleButton") :: TextButton
	local noclipStatusLabel = noclipSection:WaitForChild("Status") :: TextLabel

	local waypointsSection = worldTab:WaitForChild("WaypointsSection")
	local waypointNameBox = waypointsSection:WaitForChild("SaveRow"):WaitForChild("NameBox") :: TextBox
	local waypointSaveButton = waypointsSection:WaitForChild("SaveRow"):WaitForChild("SaveButton") :: TextButton
	local waypointStatusLabel = waypointsSection:WaitForChild("Status") :: TextLabel
	local waypointList = waypointsSection:WaitForChild("List")
	local waypointRows: { { row: Frame, nameLabel: TextLabel, jumpButton: TextButton, deleteButton: TextButton } } =
		{}
	for i = 1, WAYPOINT_LIMIT do
		local rowFrame = waypointList:WaitForChild("Row" .. i) :: Frame
		waypointRows[i] = {
			row = rowFrame,
			nameLabel = rowFrame:WaitForChild("NameLabel") :: TextLabel,
			jumpButton = rowFrame:WaitForChild("JumpButton") :: TextButton,
			deleteButton = rowFrame:WaitForChild("DeleteButton") :: TextButton,
		}
	end

	type TuningRowRefs = {
		value: TextLabel,
		input: TextBox,
		setButton: TextButton,
		clearButton: TextButton,
	}
	local tuningRows: { [TunableConstantName]: TuningRowRefs } = {} :: any
	for _, rawName in MovementTuning.Names do
		local name = rawName :: TunableConstantName
		local rowFrame = tuningTab:WaitForChild("Row_" .. name)
		tuningRows[name] = {
			value = rowFrame:WaitForChild("Value") :: TextLabel,
			input = rowFrame:WaitForChild("Input") :: TextBox,
			setButton = rowFrame:WaitForChild("SetButton") :: TextButton,
			clearButton = rowFrame:WaitForChild("ClearButton") :: TextButton,
		}
	end

	local trove = Trove.new()

	-- Latest broadcast from MovementValidationService, or nil until the first one
	-- arrives (docs/MOVEMENT.md: one-way server -> owning-client broadcast).
	-- `violations` (docs/MOVEMENT.md §8) is ViolationTracker's bounded recent
	-- history, not just `violationCount`'s running total.
	local serverState: {
		state: Network.DebugMovementState,
		runDuration: number?,
		violationCount: number,
		violations: { { flatDelta: number, maxDistance: number, elapsed: number, ageSeconds: number } },
	}? =
		nil

	local isOpen = false
	local fadeTargets: { FadeTarget }? = nil

	local function playFade(open: boolean)
		if not fadeTargets then
			fadeTargets = collectFadeTargets(panel)
		end
		local targets = fadeTargets :: { FadeTarget }

		if open then
			-- Snap every element fully transparent the instant `panel.Visible`
			-- flips true, so the fade-in tween below has something to fade FROM --
			-- otherwise the panel would flash its fully-opaque baked-in look for one
			-- frame before the tween catches up. Isolated per-target (not one bare
			-- loop) for the same reason as the tween loop below -- one bad
			-- assignment shouldn't silently skip snapping every target after it.
			for _, target in targets do
				local ok, err = pcall(function()
					(target.instance :: any)[target.property] = 1
				end)
				if not ok then
					warn(
						string.format(
							"[DebugOverlay] snap-to-hidden failed for %s.%s: %s",
							target.instance:GetFullName(),
							target.property,
							tostring(err)
						)
					)
				end
			end
		end

		-- Isolated per-target, not one bare loop over all of them (found
		-- 2026-09-14 while chasing the blank-panel investigation): a single
		-- TweenService:Create/property-write failure partway through would
		-- otherwise silently abort the whole loop, leaving every remaining target
		-- un-tweened with no error visible anywhere near the actual cause.
		for _, target in targets do
			local goal = if open then target.visibleValue else 1
			local ok, err = pcall(function()
				TweenService:Create(target.instance :: Instance, TWEEN_INFO, {
					[target.property] = goal,
				}):Play()
			end)
			if not ok then
				warn(
					string.format(
						"[DebugOverlay] tween failed for %s.%s: %s",
						target.instance:GetFullName(),
						target.property,
						tostring(err)
					)
				)
			end
		end
	end

	local function setOpen(open: boolean)
		if open == isOpen then
			return
		end
		isOpen = open

		-- Tells the server whether to bother broadcasting MovementDebugState
		-- at all (docs/MOVEMENT.md §10, `TRAVERSAL-ROADMAP.md` Phase 0
		-- cleanup) -- every open/close path (F4, corner tab, close button)
		-- already routes through this one function, so this is the single
		-- place that needs to fire it.
		Network.RequestSetDebugOverlayOpen.Fire(open)

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
			f4Held = false
		end
	end)

	trove:Connect(cornerTab.MouseButton1Click, function()
		setOpen(true)
	end)

	trove:Connect(closeButton.MouseButton1Click, function()
		setOpen(false)
	end)

	-- Draggable panel (docs/MOVEMENT.md §8), position remembered for the session:
	-- deliberately just leaves `panel.Position` wherever the drag ends -- nothing
	-- resets it on close/reopen (`setOpen` above never touches `Position`), so
	-- "remembered for the session" falls out for free rather than needing its own
	-- stored variable. Never persisted across sessions -- same "no reason to touch
	-- persistence for this" reasoning as the waypoints below. Standard Roblox
	-- drag-by-titlebar pattern: `TitleRow.InputBegan` captures the press-start
	-- mouse/touch position and the panel's own position at that instant,
	-- `UserInputService.InputChanged` (global -- the drag can leave the panel's own
	-- bounds mid-drag) applies the accumulated delta every frame the mouse moves.
	local dragging = false
	local dragStart = Vector2.zero
	local dragStartPosition = panel.Position
	-- Trove:Connect's return type is a plain ConnectionLike table, not the opaque
	-- RBXScriptConnection every other tracked connection in this file happens to
	-- be -- typed loosely since all this needs is `trove:Remove` on whatever comes
	-- back, never any Roblox-specific member of it.
	local dragEndConnection: any = nil

	trove:Connect(titleRow.InputBegan, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		dragging = true
		dragStart = Vector2.new(input.Position.X, input.Position.Y)
		dragStartPosition = panel.Position

		if dragEndConnection then
			trove:Remove(dragEndConnection)
		end
		dragEndConnection = trove:Connect(input.Changed, function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end)

	trove:Connect(UserInputService.InputChanged, function(input: InputObject)
		if not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
		panel.Position = UDim2.new(
			dragStartPosition.X.Scale,
			dragStartPosition.X.Offset + delta.X,
			dragStartPosition.Y.Scale,
			dragStartPosition.Y.Offset + delta.Y
		)
	end)

	-- Tabs (docs/MOVEMENT.md §8) -----------------------------------------------

	local tabButtons: { [string]: TextButton } =
		{ Movement = movementTabButton, World = worldTabButton, Tuning = tuningTabButton }
	local tabPages: { [string]: Frame } = { Movement = movementTab, World = worldTab, Tuning = tuningTab }

	local function setTab(name: string)
		for tabName, page in tabPages do
			page.Visible = tabName == name
		end
		for tabName, button in tabButtons do
			local active = tabName == name
			button.BackgroundColor3 = if active then ACCENT else BG_DARK
			button.TextColor3 = if active then BG_DARK else TEXT_MUTED
		end
	end

	trove:Connect(movementTabButton.MouseButton1Click, function()
		setTab("Movement")
	end)
	trove:Connect(worldTabButton.MouseButton1Click, function()
		setTab("World")
	end)
	trove:Connect(tuningTabButton.MouseButton1Click, function()
		setTab("Tuning")
	end)

	setTab("Movement")

	-- SetCallback returns a plain disconnector function, not an RBXScriptSignal --
	-- Trove:Add (not Trove:Connect) is what treats a bare function as a cleanup
	-- task to run on Destroy.
	trove:Add(Network.MovementDebugState.SetCallback(function(value)
		serverState = value
	end))

	-- Network claim log reconciliation (docs/MOVEMENT.md §8): DebugSnapshot's
	-- claim log starts every entry `reflected = nil` (pending) -- there's no ack
	-- remote for RequestMovementTransition (deliberately, see network.zap), so
	-- this is the only signal available for "did the server ever mirror this
	-- claim": once `serverState.state` matches the claimed state, the claim
	-- reflected; if that never happens within CLAIM_REFLECT_TIMEOUT_SECONDS, it's
	-- shown as likely-rejected instead of pending forever. Mutates
	-- ClaimLogEntry.history's entries in place, per DebugSnapshot.GetClaimLog's own
	-- documented contract.
	local function reconcileClaimLog()
		local claims = DebugSnapshot.GetClaimLog()
		local now = os.clock()
		for _, entry in claims do
			if entry.reflected == nil then
				if serverState and serverState.state == entry.state then
					entry.reflected = true
				elseif now - entry.at > CLAIM_REFLECT_TIMEOUT_SECONDS then
					entry.reflected = false
				end
			end
		end
	end

	local function renderStateHistory()
		local history = DebugSnapshot.GetStateHistory()
		local now = os.clock()
		for i, label in stateHistoryRows do
			local entry = history[i]
			if entry then
				label.Visible = true
				label.Text = string.format("%s  ·  %s", entry.state, formatAgo(now - entry.at))
				label.TextColor3 = TEXT_PRIMARY
			else
				label.Visible = i == 1
				label.Text = if i == 1 then "(no transitions yet)" else ""
				label.TextColor3 = TEXT_MUTED
			end
		end
	end

	local function renderClaimLog()
		local claims = DebugSnapshot.GetClaimLog()
		local now = os.clock()
		for i, label in claimLogRows do
			local entry = claims[i]
			if entry then
				label.Visible = true
				local status = if entry.reflected == true
					then "✓"
					elseif entry.reflected == false then "✗ unconfirmed"
					else "…"
				label.Text = string.format("%s  ·  %s  ·  %s", entry.state, formatAgo(now - entry.at), status)
				label.TextColor3 = if entry.reflected == false then TEXT_ALARM else TEXT_PRIMARY
			else
				label.Visible = i == 1
				label.Text = if i == 1 then "(no claims yet)" else ""
				label.TextColor3 = TEXT_MUTED
			end
		end
	end

	local function renderViolationHistory()
		local entries = if serverState then serverState.violations else nil
		for i, label in violationHistoryRows do
			local entry = entries and entries[i]
			if entry then
				label.Visible = true
				label.Text = string.format(
					"Δ%.1f / cap %.1f  ·  %s",
					entry.flatDelta,
					entry.maxDistance,
					formatAgo(entry.ageSeconds)
				)
				label.TextColor3 = TEXT_ALARM
			else
				label.Visible = i == 1
				label.Text = if i == 1 then "(no violations yet)" else ""
				label.TextColor3 = TEXT_MUTED
			end
		end
	end

	-- Only updates the readout while the panel is actually visible -- cheap
	-- either way, but there's no reason to touch a few dozen TextLabels a frame
	-- for a panel nobody's looking at. Updates every tab's data every tick
	-- (not just the active one), same reasoning as Movement/init.luau's own
	-- unconditional-publish comment -- a few extra string.format calls is not
	-- worth gating on which tab happens to be selected.
	trove:Connect(RunService.Heartbeat, function()
		if not isOpen then
			return
		end

		local client = DebugSnapshot.Get()
		clientStateValue.Text = formatState(client.state)
		clientGroundedValue.Text = formatBool(client.grounded)
		clientRunDurationValue.Text = formatDuration(client.runDuration)
		clientSpeedValue.Text = formatSpeed(client.speed)
		clientVelocityValue.Text = formatVector(client.velocity)
		clientRotVelocityValue.Text = formatVector(client.rotVelocity)
		renderStateHistory()

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
		renderViolationHistory()

		reconcileClaimLog()
		renderClaimLog()

		local noclipActive = client.noclip
		noclipToggleButton.Text = if noclipActive then "Disable Noclip" else "Enable Noclip"
		noclipToggleButton.BackgroundColor3 = if noclipActive then ACCENT else BG_DARK
		noclipToggleButton.TextColor3 = if noclipActive then BG_DARK else TEXT_PRIMARY

		for _, rawName in MovementTuning.Names do
			local name = rawName :: TunableConstantName
			local refs = tuningRows[name]
			if not UserInputService:GetFocusedTextBox() or UserInputService:GetFocusedTextBox() ~= refs.input then
				refs.value.Text = string.format("%.2f", (TuningSnapshot.Get() :: any)[name])
			end
		end
	end)

	-- Teleport tool -----------------------------------------------------------

	local function teleportTo(position: Vector3)
		Network.RequestDevTeleport.Fire(vector.create(position.X, position.Y, position.Z))
		teleportStatusLabel.Text =
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
			teleportStatusLabel.Text = "Pick cancelled."
			return
		end

		picking = true
		pickButton.Text = "Click anywhere…"
		teleportStatusLabel.Text = "Click anywhere in the world to teleport there."

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
					teleportStatusLabel.Text = "Pick missed -- no part hit."
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

	-- Noclip toggle -------------------------------------------------------------
	-- Fires the opposite of the last SERVER-CONFIRMED state (`DebugSnapshot.Get().
	-- noclip`, populated from Network.NoclipState's own confirmation in
	-- Movement/init.luau), never a locally-tracked "what did I just click" flag --
	-- so a dropped/rate-limited request can't leave this button's next click
	-- guessing wrong about which way to toggle (docs/MOVEMENT.md §8).
	trove:Connect(noclipToggleButton.MouseButton1Click, function()
		local currentlyActive = DebugSnapshot.Get().noclip
		Network.RequestSetNoclip.Fire(not currentlyActive)
		noclipStatusLabel.Text = if currentlyActive then "Requested noclip off…" else "Requested noclip on…"
	end)

	-- Waypoints -----------------------------------------------------------------
	-- Session-only, client-side (docs/MOVEMENT.md §8) -- a plain local list, never
	-- ProfileStore-backed. Jumping reuses RequestDevTeleport (the same remote the
	-- coordinate/pick tools above already use) rather than a new remote.
	local waypoints: { Waypoint } = {}

	local function renderWaypoints()
		for i, refs in waypointRows do
			local waypoint = waypoints[i]
			if waypoint then
				refs.row.Visible = true
				refs.nameLabel.Text = waypoint.name
			else
				refs.row.Visible = false
			end
		end
	end

	trove:Connect(waypointSaveButton.MouseButton1Click, function()
		local name = waypointNameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			waypointStatusLabel.Text = "Enter a name before saving."
			return
		end

		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not rootPart or not rootPart:IsA("BasePart") then
			waypointStatusLabel.Text = "No character to save a position from."
			return
		end

		local position = rootPart.Position
		local existing: Waypoint? = nil
		for _, waypoint in waypoints do
			if waypoint.name == name then
				existing = waypoint
				break
			end
		end

		if existing then
			existing.position = position
			waypointStatusLabel.Text = string.format("Updated %q.", name)
		elseif #waypoints >= WAYPOINT_LIMIT then
			waypointStatusLabel.Text = string.format("Waypoint limit reached (%d).", WAYPOINT_LIMIT)
			return
		else
			table.insert(waypoints, { name = name, position = position })
			waypointStatusLabel.Text = string.format("Saved %q.", name)
		end

		waypointNameBox.Text = ""
		renderWaypoints()
	end)

	for i, refs in waypointRows do
		trove:Connect(refs.jumpButton.MouseButton1Click, function()
			local waypoint = waypoints[i]
			if waypoint then
				teleportTo(waypoint.position)
			end
		end)
		trove:Connect(refs.deleteButton.MouseButton1Click, function()
			local waypoint = waypoints[i]
			if waypoint then
				table.remove(waypoints, i)
				waypointStatusLabel.Text = string.format("Deleted %q.", waypoint.name)
				renderWaypoints()
			end
		end)
	end

	renderWaypoints()

	-- Live tuning ---------------------------------------------------------------
	-- Reads/writes go through RequestSetTuning (network.zap), dev-gated server-side
	-- via DevToolsService.RegisterDevOnly (docs/MOVEMENT.md §1/§8) -- this
	-- controller only ever sends a claim, the server decides whether it's legal
	-- and bounds-checked (MovementTuning.IsValidValue) before it ever affects this
	-- session's EffectiveMovementConstants.
	for _, rawName in MovementTuning.Names do
		local name = rawName :: TunableConstantName
		local refs = tuningRows[name]

		trove:Connect(refs.setButton.MouseButton1Click, function()
			local value = tonumber(refs.input.Text)
			if not value then
				return
			end
			Network.RequestSetTuning.Fire({ name = name, value = value })
			refs.input.Text = ""
		end)

		trove:Connect(refs.clearButton.MouseButton1Click, function()
			Network.RequestSetTuning.Fire({ name = name, value = nil })
			refs.input.Text = ""
		end)
	end
end

return DebugOverlayController
