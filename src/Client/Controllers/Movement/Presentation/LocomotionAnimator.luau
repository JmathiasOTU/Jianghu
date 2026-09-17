--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local InputController = require(script.Parent.Parent.InputController)
local CharacterMover = require(script.Parent.Parent.CharacterMover)
local TuningSnapshot = require(script.Parent.Parent.TuningSnapshot)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

-- Short, not indefinite: these Animation instances always exist once
-- Assets/Animations/Movement.model.json is synced (docs/MOVEMENT.md §4), so this
-- only ever actually waits if that tree is missing or a name drifted out of sync
-- with DIRECTION_NAMES below -- it should never block a real, up-to-date sync.
local ANIMATION_LOOKUP_TIMEOUT_SECONDS = 1

local DIRECTION_NAMES: { string } =
	{ "Forward", "ForwardRight", "Right", "BackRight", "Back", "BackLeft", "Left", "ForwardLeft" }

-- Resolved once at module load, not per-life: this content is static and always
-- synced before any character exists, so there's no reason to re-look it up on
-- every respawn.
local ANIMATIONS_ROOT =
	ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Animations"):WaitForChild("Movement")
local WALK_FOLDER = ANIMATIONS_ROOT:WaitForChild("Walk")

export type LocomotionAnimator = {
	Destroy: (self: LocomotionAnimator) -> (),
}

local LocomotionAnimator = {}
LocomotionAnimator.__index = LocomotionAnimator

-- Facing-relative angle from `facing` to `moveDirection`, bucketed into one of the
-- 8 directions named above. 0deg (Forward) means moving the way you're facing;
-- positive angles go clockwise (docs/MOVEMENT.md §1: input direction relative to
-- facing selects the animation, not world-space direction).
local function resolveDirectionBucket(facing: Vector3, moveDirection: Vector3): string
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	local flatMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flatFacing.Magnitude == 0 or flatMove.Magnitude == 0 then
		return "Forward"
	end
	flatFacing = flatFacing.Unit
	flatMove = flatMove.Unit

	-- flatMove:Cross(flatFacing), not the other way around -- Roblox's Cross
	-- follows the right-hand rule, and facing:Cross(move) gives the sign for a
	-- clockwise-from-facing-to-move rotation, which is backwards from what "Right"
	-- means here. Swapped operand order fixes a left/right (and diagonal) mirror
	-- bug found 2026-09-13: Forward/Back were unaffected (parallel/anti-parallel
	-- vectors cross to zero either way), but every lateral bucket was flipped.
	local cross = flatMove:Cross(flatFacing)
	local angle = math.atan2(cross.Y, flatFacing:Dot(flatMove))
	local degrees = math.deg(angle)
	if degrees < 0 then
		degrees += 360
	end

	local index = math.floor((degrees + 22.5) / 45) % 8
	return DIRECTION_NAMES[index + 1]
end

-- Looks up a real, Rojo-synced Animation instance under `container` rather than
-- building a throwaway one at runtime (docs/MOVEMENT.md §4) -- keeps AnimationIds
-- version-controlled and editable in Studio instead of hardcoded strings. A missing
-- child (timeout) or one nobody's authored yet (blank AnimationId) are both treated
-- as "not ready" and skipped, exactly like the old nil-string check did.
-- `looped` (docs/MOVEMENT.md §10) -- every original Step 3 slot was a
-- continuous locomotion loop, so `Looped` was unconditionally forced true
-- here (`AnimationTrack.Looped` defaults to false, which would play once and
-- freeze). Jump/Land/LandHard are one-shots and need that default false
-- behavior preserved; Fall stays looped like the original set, since a fall
-- can last arbitrarily long.
local function loadTrack(
	animator: Animator,
	container: Instance,
	name: string,
	trove: Trove.Trove,
	looped: boolean
): AnimationTrack?
	local animation = container:WaitForChild(name, ANIMATION_LOOKUP_TIMEOUT_SECONDS) :: Animation?
	if not animation then
		warn(
			string.format(
				"[LocomotionAnimator] %s: no child named %q under %s (sync/name mismatch?)",
				container:GetFullName(),
				name,
				container:GetFullName()
			)
		)
		return nil
	end
	if animation.AnimationId == "" then
		print(
			string.format(
				"[LocomotionAnimator] %s.%s found but AnimationId is blank -- not authored yet",
				container:GetFullName(),
				name
			)
		)
		return nil
	end
	print(
		string.format(
			"[LocomotionAnimator] loaded %s.%s (%s)",
			container:GetFullName(),
			name,
			animation.AnimationId
		)
	)
	local track = trove:Add(animator:LoadAnimation(animation), "Destroy")
	track.Looped = looped
	return track
end

-- Picks/blends among Idle/Run/Sprint's single clip or Walk's 8 directional anims
-- from (facing-relative input angle, current state); reads the FSM and
-- InputController, never writes to either (docs/MOVEMENT.md §1/§3). Only Walk is
-- directional -- Run has one clip regardless of facing-relative angle, same as
-- Sprint. "Blends" here means a simple crossfade between whichever single track is
-- currently selected and the next -- not a weighted multi-track blend space.
-- Revisit once real animations exist and playtesting says a discrete
-- switch-with-fade isn't smooth enough.
function LocomotionAnimator.new(
	humanoid: Humanoid,
	rootPart: BasePart,
	fsm: StateMachine.StateMachine<MovementState, MovementContext>,
	inputController: InputController.InputController,
	characterMover: CharacterMover.CharacterMover
): LocomotionAnimator
	local self = setmetatable({}, LocomotionAnimator) :: any
	self._trove = Trove.new()
	self._humanoid = humanoid
	self._rootPart = rootPart
	self._fsm = fsm
	self._inputController = inputController
	self._characterMover = characterMover
	self._currentKey = nil :: string?
	-- One-shot-on-exit hold, shared by every synchronous-frame/instant-cue
	-- state (Land, SlideJump): when set, `_update` plays `.key`
	-- unconditionally until `os.clock()` passes `.until`, overriding normal
	-- per-state resolution -- by the time these are detected the FSM has
	-- already moved past the state that should show them.
	self._transientHold = nil :: { key: string, until_: number }?

	-- Roblox's default "Animate" script fights this system's own tracks if left
	-- alive -- destroy it now, and destroy it again if it shows up later
	-- (StarterCharacterScripts can clone it in after CharacterAdded fires).
	local character = humanoid.Parent
	local defaultAnimateScript = character and character:FindFirstChild("Animate")
	if defaultAnimateScript then
		defaultAnimateScript:Destroy()
	end
	if character then
		self._trove:Connect(character.ChildAdded, function(child: Instance)
			if child.Name == "Animate" then
				child:Destroy()
			end
		end)
	end

	print("[LocomotionAnimator] new() constructing for " .. (character and character.Name or "?"))
	local animator = humanoid:WaitForChild("Animator") :: Animator

	self._tracks = {} :: { [string]: AnimationTrack? }
	self._tracks.Idle = loadTrack(animator, ANIMATIONS_ROOT, "Idle", self._trove, true)
	self._tracks.Run = loadTrack(animator, ANIMATIONS_ROOT, "Run", self._trove, true)
	self._tracks.Sprint = loadTrack(animator, ANIMATIONS_ROOT, "Sprint", self._trove, true)
	-- CrouchIdle/CrouchWalk/Slide (docs/MOVEMENT.md §9): single non-directional
	-- clips, same as Idle/Run/Sprint above -- read from ANIMATIONS_ROOT, not
	-- WALK_FOLDER, even though they were first authored as stray children of the
	-- Walk folder (moved out in Assets/Animations/Movement.model.json alongside
	-- this fix; found and fixed together, since the animator never referenced
	-- them under either name until now).
	self._tracks.CrouchIdle = loadTrack(animator, ANIMATIONS_ROOT, "CrouchIdle", self._trove, true)
	self._tracks.CrouchWalk = loadTrack(animator, ANIMATIONS_ROOT, "CrouchWalk", self._trove, true)
	self._tracks.Slide = loadTrack(animator, ANIMATIONS_ROOT, "Slide", self._trove, true)
	for _, direction in DIRECTION_NAMES do
		self._tracks["Walk_" .. direction] =
			loadTrack(animator, WALK_FOLDER, direction, self._trove, true)
	end
	-- Landing/falling (Traversal Roadmap §8 Phase 0, docs/MOVEMENT.md §10):
	-- Jump/Fall read every frame while Airborne (below); Land/LandHard are
	-- one-shots played on the Airborne->grounded edge. Fall stays looped (a
	-- fall can last arbitrarily long); Jump/Land/LandHard do not.
	self._tracks.Jump = loadTrack(animator, ANIMATIONS_ROOT, "Jump", self._trove, false)
	self._tracks.SlideJump = loadTrack(animator, ANIMATIONS_ROOT, "SlideJump", self._trove, false)
	self._tracks.Fall = loadTrack(animator, ANIMATIONS_ROOT, "Fall", self._trove, true)
	self._tracks.Land = loadTrack(animator, ANIMATIONS_ROOT, "Land", self._trove, false)
	self._tracks.LandHard = loadTrack(animator, ANIMATIONS_ROOT, "LandHard", self._trove, false)
	-- DoubleJump (TRAVERSAL-ROADMAP.md Phase 1): a one-shot, not looped -- the
	-- impulse itself is a short, fixed-duration decay (DoubleJumpDecayDurationSeconds),
	-- same treatment as Jump rather than the indefinite Fall loop.
	self._tracks.DoubleJump = loadTrack(animator, ANIMATIONS_ROOT, "DoubleJump", self._trove, false)

	-- Landing detection (docs/MOVEMENT.md §10; corrected TRAVERSAL-ROADMAP.md
	-- Phase 1; simplified again once HardLanding became a real FSM state): an
	-- edge out of an airborne-family state (Airborne or DoubleJump) is only a
	-- LANDING if it actually arrives grounded -- checking `previous` alone
	-- stopped being sufficient the moment `DoubleJump` became a real Airborne
	-- exit that ISN'T a landing (Airborne -> DoubleJump is still airborne,
	-- just a new impulse). Also covers the rarer reverse case, DoubleJump -> a
	-- grounded state directly (landed mid-impulse, `DoubleJumpState.Update`'s
	-- own mid-air-landing branch) -- `previous == DoubleJump` alone would
	-- otherwise miss it.
	--
	-- `next == HardLanding` is deliberately excluded from the one-shot hold
	-- below: severity is no longer an animator-local velocity read
	-- (`HardLandingFallSpeedThreshold` is gone -- see `AirborneState.
	-- ResolveLandingTarget`'s real `fallHeight` check instead), it's now
	-- which grounded state the FSM actually landed in. A landing INTO
	-- HardLanding needs no hold of its own -- it's a real state that persists
	-- for its own real lock duration, so per-state resolution below already
	-- plays "LandHard" for as long as `fsm.current` says so. Only a landing
	-- into any OTHER grounded state still needs this brief "Land" overlay.
	self._trove:Connect(fsm.changed, function(next: MovementState, previous: MovementState)
		-- SlideJump lasts exactly one synchronous frame before handing off to
		-- Airborne -- `_update` runs on RenderStepped, so `fsm.current` is
		-- never actually observed as SlideJump on a real rendered frame, and
		-- per-state resolution below would never pick the clip. Held for a
		-- fixed window starting the instant it's exited, overriding normal
		-- resolution. Prefers the real clip length (`AnimationTrack.Length`)
		-- so retiming the authored animation doesn't require a matching code
		-- change; `MovementConstants.OneShotAnimationHoldFallbackSeconds` is
		-- only a fallback for the (should-never-happen) case that Length
		-- reads 0.
		if previous == MovementStates.SlideJump then
			local track = self._tracks.SlideJump
			local duration = (track and track.Length > 0) and track.Length
				or MovementConstants.OneShotAnimationHoldFallbackSeconds
			self:_setTransientHold("SlideJump", duration)
		end

		local fromAirborneFamily = previous == MovementStates.Airborne
			or previous == MovementStates.DoubleJump
		if not fromAirborneFamily or not self._characterMover:IsGrounded() or next == MovementStates.HardLanding then
			return
		end
		-- An immediate landing (e.g. a slide jump off a tiny ledge) should show
		-- the real landing clip, not keep holding a one-shot past its welcome.
		self:_setTransientHold("Land", TuningSnapshot.Get().LandingAnimationHoldSeconds)
	end)

	self._trove:Connect(RunService.RenderStepped, function()
		self:_update()
	end)

	return self
end

function LocomotionAnimator:_setTransientHold(key: string, duration: number)
	self._transientHold = { key = key, until_ = os.clock() + duration }
end

function LocomotionAnimator:_update()
	-- One-shot-on-exit hold wins over normal per-state resolution below until
	-- the window elapses -- see the fsm.changed connection in `.new` for why
	-- this can't just be handled inline below (by the time one of these is
	-- set, `fsm.current` has already moved past the state that should show it).
	if self._transientHold then
		if os.clock() < self._transientHold.until_ then
			self:_playKey(self._transientHold.key)
			return
		end
		self._transientHold = nil
	end

	local state = self._fsm.current
	local key: string? = nil

	if state == MovementStates.Idle then
		key = "Idle"
	elseif state == MovementStates.Run then
		key = "Run"
	elseif state == MovementStates.Sprint then
		key = "Sprint"
	elseif state == MovementStates.CrouchIdle then
		key = "CrouchIdle"
	elseif state == MovementStates.CrouchWalk then
		key = "CrouchWalk"
	elseif state == MovementStates.Slide then
		key = "Slide"
	elseif state == MovementStates.Walk then
		local moveIntent = self._inputController:GetMoveIntent()
		if moveIntent.direction.Magnitude > 0 then
			-- Bucketing only matters while the camera is locked to the character
			-- (docs/MOVEMENT.md §4) -- unlocked, AutoRotate swings facing toward
			-- movement direction gradually rather than snapping, and during that
			-- swing the angle sweeps through several buckets in quick succession,
			-- each one stopping/crossfading a new track (stutter, fixed
			-- 2026-09-13). Unlocked, you're always facing where you walk by
			-- definition, so there's nothing to bucket -- always Forward.
			local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			local bucket = "Forward"
			if locked then
				local facing = self._rootPart.CFrame.LookVector
				bucket = resolveDirectionBucket(facing, moveIntent.direction)
			end
			key = "Walk_" .. bucket
		end
	elseif state == MovementStates.Airborne then
		-- Rising vs falling (docs/MOVEMENT.md §10): `Humanoid:GetState()`
		-- already distinguishes `Jumping` (ascent) from `Freefall` (descent) --
		-- the same read `CharacterMover:IsJumping()` uses for SlideJump's entry
		-- gate. Anything else (e.g. the single tick `Landed` reports before the
		-- FSM's own `changed` fires) falls through to nil, same as before.
		local humanoidState = self._humanoid:GetState()
		if humanoidState == Enum.HumanoidStateType.Jumping then
			key = "Jump"
		elseif humanoidState == Enum.HumanoidStateType.Freefall then
			key = "Fall"
		end
	elseif state == MovementStates.DoubleJump then
		key = "DoubleJump"
	elseif state == MovementStates.SlideJump then
		key = "SlideJump"
	elseif state == MovementStates.HardLanding then
		key = "LandHard"
	end
	-- Walk with no move direction this frame: key stays nil, fading out
	-- whatever was last playing.

	self:_playKey(key)
end

function LocomotionAnimator:_playKey(key: string?)
	if key == self._currentKey then
		return
	end
	self._currentKey = key

	-- Live-tunable (docs/MOVEMENT.md §8, moved off a module-local constant in
	-- the 2026-09-15 cleanup pass, same TuningSnapshot pipeline
	-- LandingAnimationHoldSeconds already uses) -- read fresh per call rather
	-- than cached, so a Studio Tuning-tab change takes effect on the very next
	-- state switch with no extra invalidation bookkeeping.
	local fadeTime = TuningSnapshot.Get().AnimationFadeTimeSeconds

	for trackKey, track in self._tracks do
		if track and trackKey ~= key and track.IsPlaying then
			track:Stop(fadeTime)
		end
	end

	local nextTrack = key and self._tracks[key]
	if nextTrack and not nextTrack.IsPlaying then
		nextTrack:Play(fadeTime)
	end
end

function LocomotionAnimator:Destroy()
	self._trove:Destroy()
end

return LocomotionAnimator
