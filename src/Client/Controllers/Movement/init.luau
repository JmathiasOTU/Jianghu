--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)

local CharacterMover = require(script.CharacterMover)
local InputController = require(script.InputController)
local ClientMovementContextModule = require(script.ClientMovementContext)
local DebugSnapshot = require(script.DebugSnapshot)
local TuningSnapshot = require(script.TuningSnapshot)
local NoclipController = require(script.NoclipController)
local Network = require(script.Parent.Parent.Network.network)

local FacingController = require(script.Presentation.FacingController)
local LocomotionAnimator = require(script.Presentation.LocomotionAnimator)

local IdleState = require(script.States.IdleState)
local WalkState = require(script.States.WalkState)
local RunState = require(script.States.RunState)
local SprintState = require(script.States.SprintState)
local AirborneState = require(script.States.AirborneState)

type MovementState = MovementStates.MovementState
type ClientMovementContext = ClientMovementContextModule.ClientMovementContext

-- This folder syncs as a single ModuleScript via init.luau (not a flat
-- MovementController.luau) specifically so InputController/CharacterMover/States
-- can live as real children reachable via `script.X` -- ClientBootstrap's
-- Loader.LoadChildren(Controllers) only requires DIRECT children of Controllers,
-- never descendants, so anything placed flat under a `Controllers/Movement/`
-- subfolder without this init.luau trick would silently never get Init'd.
local MovementController = {}

local States = {
	[MovementStates.Idle] = IdleState,
	[MovementStates.Walk] = WalkState,
	[MovementStates.Run] = RunState,
	[MovementStates.Sprint] = SprintState,
	[MovementStates.Airborne] = AirborneState,
}

-- Only Run/Sprint are earned, exploit-relevant transitions that need a server
-- claim (see docs/MOVEMENT.md §5) -- Idle/Walk/Airborne need no remote.
local NETWORK_CLAIM_NAMES: { [MovementState]: "Run" | "Sprint" } = {
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
}

-- Symbol -> plain string name for the F4 debug overlay's DebugSnapshot
-- (docs/MOVEMENT.md) -- the overlay has no reason to require MovementStates just
-- to compare Symbols for display, a string is enough for a readout.
local DEBUG_STATE_NAMES: { [MovementState]: string } = {
	[MovementStates.Idle] = "Idle",
	[MovementStates.Walk] = "Walk",
	[MovementStates.Run] = "Run",
	[MovementStates.Sprint] = "Sprint",
	[MovementStates.Airborne] = "Airborne",
}

-- How often the current Run/Sprint claim is re-sent while held, not just on the
-- transition edge (found 2026-09-13, docs/MOVEMENT.md §5: real playtest logs
-- showed the server mirror stuck at Run while the player was genuinely sprinting
-- the whole time). The claim fires once on `fsm.changed`, fire-and-forget with no
-- ack -- if that single packet is ever rejected (e.g. the dwell reads a hair under
-- threshold due to ordinary jitter right at the 3s boundary) or dropped, the
-- client's own FSM is already in Sprint and never transitions again, so it never
-- naturally resends. Periodic reassertion makes that self-healing: a `RequestTransition`
-- for the state the FSM mirror is already in is a harmless no-op server-side
-- (`next == current` fails legality trivially), so this only ever repairs a
-- desync, never causes one. A network-reliability concern, not gameplay tuning --
-- lives here rather than MovementConstants for the same reason
-- TRANSITION_CLAIMS_PER_SECOND lives in MovementValidationService instead of
-- there.
local CLAIM_RESYNC_INTERVAL_SECONDS = 1

local input: InputController.InputController

local function setupCharacter(character: Model, lifeTrove: Trove.Trove)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	local characterMover = lifeTrove:Add(CharacterMover.new(humanoid, TuningSnapshot.Get().JumpPower))
	local noclip = lifeTrove:Add(NoclipController.new(humanoid, rootPart, input))
	local fsm = lifeTrove:Add(
		StateMachine.new(MovementStates.Idle, StateRules.Transitions, StateRules.CanEnter)
	)

	-- Presentation: purely cosmetic, never touched by states or the FSM (they only
	-- read it) -- docs/MOVEMENT.md §3/§4.
	lifeTrove:Add(FacingController.new(humanoid, rootPart))
	lifeTrove:Add(LocomotionAnimator.new(humanoid, rootPart, fsm, input))

	-- Live tuning (docs/MOVEMENT.md §8): pushes the server's effective-constants
	-- broadcast into TuningSnapshot and re-applies JumpPower immediately, since
	-- unlike WalkSpeed/RunSpeed/SprintSpeed (only ever set on a state's own
	-- Enter), JumpPower has no per-frame/per-transition write site of its own to
	-- naturally pick up a changed value.
	lifeTrove:Add(Network.TuningState.SetCallback(function(value)
		TuningSnapshot.Set({
			RunDoubleTapWindowSeconds = value.runDoubleTapWindowSeconds,
			SprintThresholdSeconds = value.sprintThresholdSeconds,
			WalkSpeed = value.walkSpeed,
			RunSpeed = value.runSpeed,
			SprintSpeed = value.sprintSpeed,
			JumpPower = value.jumpPower,
			SprintForwardDeadzone = value.sprintForwardDeadzone,
			SpeedToleranceMultiplier = value.speedToleranceMultiplier,
		})
		characterMover:SetJumpPower(value.jumpPower)
	end))

	-- Noclip/fly (docs/MOVEMENT.md §8): the server is the sole authority on
	-- whether this session is noclipping (Server/State/NoclipState.luau) --
	-- this callback is what lets the local NoclipController actually start/stop
	-- driving the character once the server confirms the toggle, never a
	-- client-side guess ahead of that confirmation.
	local noclipActive = false
	lifeTrove:Add(Network.NoclipState.SetCallback(function(enabled: boolean)
		noclipActive = enabled
		noclip:SetActive(enabled)
	end))

	local function buildContext(): ClientMovementContext
		local runDuration = if fsm.current == MovementStates.Run
			then RunState.GetDuration()
			else nil
		return {
			moveIntent = input:GetMoveIntent(),
			grounded = characterMover:IsGrounded(),
			runDuration = runDuration,
			constants = TuningSnapshot.Get(),
			characterMover = characterMover,
			fsm = fsm,
		}
	end

	-- The FSM starts already in Idle, so no `changed` fires for it -- Enter has to
	-- run once up front to stay symmetric with every later transition.
	IdleState.Enter(buildContext())

	local lastClaimResyncAt = 0

	local function fireClaim(claimName: "Run" | "Sprint")
		Network.RequestMovementTransition.Fire(claimName)
		DebugSnapshot.RecordClaim(claimName)
		lastClaimResyncAt = os.clock()
	end

	lifeTrove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		States[previous].Exit(buildContext())
		States[next].Enter(buildContext())

		-- F4 debug overlay state history (docs/MOVEMENT.md §8): populated off
		-- this existing `fsm.changed` connection, not a new one.
		DebugSnapshot.RecordTransition(DEBUG_STATE_NAMES[next])

		local claimName = NETWORK_CLAIM_NAMES[next]
		if claimName then
			fireClaim(claimName)
		end
	end)

	lifeTrove:Connect(input.RunRequested, function()
		fsm:RequestTransition(MovementStates.Run, buildContext())
	end)

	lifeTrove:Connect(RunService.Heartbeat, function(dt: number)
		States[fsm.current].Update(dt, buildContext())

		local claimName = NETWORK_CLAIM_NAMES[fsm.current]
		if claimName and os.clock() - lastClaimResyncAt >= CLAIM_RESYNC_INTERVAL_SECONDS then
			fireClaim(claimName)
		end

		-- F4 debug overlay (docs/MOVEMENT.md) -- published every Heartbeat
		-- regardless of whether the overlay is even open, same as how the FSM's own
		-- context is rebuilt unconditionally; cheap enough (a few field reads, no
		-- allocation-heavy work) not to bother gating on overlay visibility.
		local velocity = rootPart.AssemblyLinearVelocity
		local rotVelocity = rootPart.AssemblyAngularVelocity
		DebugSnapshot.Set({
			state = DEBUG_STATE_NAMES[fsm.current],
			grounded = characterMover:IsGrounded(),
			runDuration = if fsm.current == MovementStates.Run then RunState.GetDuration() else nil,
			speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
			velocity = velocity,
			rotVelocity = rotVelocity,
			noclip = noclipActive,
		})
	end)
end

function MovementController.Init()
	input = InputController.new()

	local player = Players.LocalPlayer
	local lifeTrove: Trove.Trove? = nil

	local function onCharacterAdded(character: Model)
		if lifeTrove then
			lifeTrove:Destroy()
		end
		lifeTrove = Trove.new()
		setupCharacter(character, lifeTrove)
	end

	player.CharacterAdded:Connect(onCharacterAdded)
	player.CharacterRemoving:Connect(function()
		if lifeTrove then
			lifeTrove:Destroy()
			lifeTrove = nil
		end
	end)

	if player.Character then
		onCharacterAdded(player.Character)
	end
end

return MovementController
