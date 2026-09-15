--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Trove = require(ReplicatedStorage.Packages.Trove)
local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local InputController = require(script.Parent.Parent.InputController)
local CharacterMover = require(script.Parent.Parent.CharacterMover)
local TuningSnapshot = require(script.Parent.Parent.TuningSnapshot)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

local FADE_TIME = 0.15

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
	-- Landing one-shot hold (docs/MOVEMENT.md §10): when set, `_update` plays
	-- `_landingKey` unconditionally until `os.clock()` passes this, overriding
	-- normal per-state resolution -- by the time a landing is detected the FSM
	-- has already transitioned off Airborne, so without this the one-shot
	-- would never be seen.
	self._landingKey = nil :: string?
	self._landingHoldUntil = nil :: number?

	-- Roblox auto-adds a default "Animate" script to every character, which plays
	-- its own walk/idle/jump animations on this same Humanoid/Animator
	-- automatically based on MoveDirection/state -- entirely independent of this
	-- system. Left alone, both play tracks on the same joints at once, which reads
	-- as the animations visibly fighting/flickering. This system fully replaces
	-- it, so it's destroyed (not just disabled) the moment LocomotionAnimator takes
	-- over -- bug found 2026-09-13, missed when Step 3 first shipped.
	local character = humanoid.Parent
	local defaultAnimateScript = character and character:FindFirstChild("Animate")
	if defaultAnimateScript then
		defaultAnimateScript:Destroy()
		print("[LocomotionAnimator] destroyed default Animate script on " .. character.Name)
	else
		print(
			"[LocomotionAnimator] no default Animate script found on "
				.. (character and character.Name or "?")
				.. " (already removed, or this ran before it existed)"
		)
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
	-- them under either name until now). SlideJump has no clip of its own --
	-- it's a brief mid-air hop immediately followed by Airborne (see below);
	-- flagged in the Traversal Roadmap as a one-line extension to reuse "Jump"
	-- if wanted later, not done here.
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
	self._tracks.Fall = loadTrack(animator, ANIMATIONS_ROOT, "Fall", self._trove, true)
	self._tracks.Land = loadTrack(animator, ANIMATIONS_ROOT, "Land", self._trove, false)
	self._tracks.LandHard = loadTrack(animator, ANIMATIONS_ROOT, "LandHard", self._trove, false)
	-- DoubleJump (TRAVERSAL-ROADMAP.md Phase 1): a one-shot, not looped -- the
	-- impulse itself is a short, fixed-duration decay (DoubleJumpDecayDurationSeconds),
	-- same treatment as Jump rather than the indefinite Fall loop.
	self._tracks.DoubleJump = loadTrack(animator, ANIMATIONS_ROOT, "DoubleJump", self._trove, false)

	-- Landing detection (docs/MOVEMENT.md §10; corrected TRAVERSAL-ROADMAP.md
	-- Phase 1): an edge out of an airborne-family state (Airborne or
	-- DoubleJump) is only a LANDING if it actually arrives grounded --
	-- checking `previous` alone stopped being sufficient the moment
	-- `DoubleJump` became a real Airborne exit that ISN'T a landing
	-- (Airborne -> DoubleJump is still airborne, just a new impulse). Also
	-- covers the rarer reverse case, DoubleJump -> a grounded state directly
	-- (landed mid-impulse, `DoubleJumpState.Update`'s own mid-air-landing
	-- branch) -- `previous == DoubleJump` alone would otherwise miss it.
	-- Reads vertical speed at this exact instant -- one frame later and the
	-- Landed->grounded physics state has already damped it.
	self._trove:Connect(fsm.changed, function(_next: MovementState, previous: MovementState)
		local fromAirborneFamily = previous == MovementStates.Airborne or previous == MovementStates.DoubleJump
		if not fromAirborneFamily or not self._characterMover:IsGrounded() then
			return
		end
		local fallSpeed = -self._characterMover:GetVerticalVelocity()
		local hardThreshold = TuningSnapshot.Get().HardLandingFallSpeedThreshold
		self._landingKey = if fallSpeed >= hardThreshold then "LandHard" else "Land"
		self._landingHoldUntil = os.clock() + TuningSnapshot.Get().LandingAnimationHoldSeconds
	end)

	self._trove:Connect(RunService.RenderStepped, function()
		self:_update()
	end)

	return self
end

function LocomotionAnimator:_update()
	-- Landing one-shot hold (docs/MOVEMENT.md §10) wins over normal per-state
	-- resolution below until the window elapses -- see the fsm.changed
	-- connection in `.new` for why this can't just be handled inline below.
	if self._landingHoldUntil then
		if os.clock() < self._landingHoldUntil then
			self:_playKey(self._landingKey)
			return
		end
		self._landingHoldUntil = nil
		self._landingKey = nil
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
	end
	-- SlideJump, or Walk with no move direction this frame: key stays nil,
	-- fading out whatever was last playing -- same "add a clip here once one
	-- exists" deferred treatment SlideJump still has.

	self:_playKey(key)
end

function LocomotionAnimator:_playKey(key: string?)
	if key == self._currentKey then
		return
	end
	self._currentKey = key

	for trackKey, track in self._tracks do
		if track and trackKey ~= key and track.IsPlaying then
			track:Stop(FADE_TIME)
		end
	end

	local nextTrack = key and self._tracks[key]
	if nextTrack and not nextTrack.IsPlaying then
		nextTrack:Play(FADE_TIME)
	end
end

function LocomotionAnimator:Destroy()
	self._trove:Destroy()
end

return LocomotionAnimator
