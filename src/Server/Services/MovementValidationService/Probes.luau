--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)

local Sessions = require(script.Parent.Sessions)

type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- The server's own reads of the world around each character (audit
-- M-004): support under the feet (its ground truth), how much of the
-- floor's velocity it can vouch for, and the throttled fall-height, slide
-- ground and wall probes. Never anything the client reports.
local Probes = {}

local function isGrounded(state: Enum.HumanoidStateType): boolean
	return state == Enum.HumanoidStateType.Running
		or state == Enum.HumanoidStateType.RunningNoPhysics
		or state == Enum.HumanoidStateType.Landed
end

-- How much of a floor's velocity the server can vouch for (re-audit N-003),
-- as (horizontal speed, upward speed). Anchored geometry and server-owned
-- physics parts are moved by the server, so their velocity is real. Another
-- player's character is moved by that player's client: its horizontal speed
-- is believed up to what that player is itself allowed to carry, its vertical
-- speed not at all. Any other unanchored part is simulated by some client --
-- possibly this one, driving the part it stands on -- so it earns nothing.
local function trustedFloorVelocity(floor: BasePart, velocity: Vector3): (number, number)
	local flat = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local rise = math.max(velocity.Y, 0)
	if floor:IsGrounded() then
		return flat, rise
	end

	local character = floor:FindFirstAncestorOfClass("Model")
	local rider = if character then Players:GetPlayerFromCharacter(character :: Model) else nil
	if rider then
		local riderSession = Sessions.ByPlayer[rider]
		return if riderSession then math.min(flat, riderSession.carrySpeed) else 0, 0
	end

	local ok, owner = pcall(function()
		return floor:GetNetworkOwner()
	end)
	if ok and owner == nil then
		return flat, rise
	end
	return 0, 0
end

-- Refreshed once per Heartbeat (and forced at claim time) before anything
-- reads `session.supported`, so every consumer in one Heartbeat agrees.
function Probes.UpdateSupport(session: PlayerSession)
	local hit = SpatialQueries.QuerySupport(session.rootPart, session.humanoid.Parent :: Instance)
	local supported = hit ~= nil
	session.supported = supported
	if hit then
		session.floorSpeed, session.floorRiseSpeed =
			trustedFloorVelocity(hit.floor, hit.floorVelocity)
	else
		session.floorSpeed, session.floorRiseSpeed = 0, 0
	end
	-- Start of the current stretch where the character is on real ground but
	-- its Humanoid label says it isn't -- reset by either one ending.
	if not supported or isGrounded(session.humanoid:GetState()) then
		session.supportedSince = nil
	elseif not session.supportedSince then
		session.supportedSince = os.clock()
	end

	-- Touching down again after a double jump refreshes it (see
	-- `doubleJumpLeftGround`).
	if session.doubleJumpUsed then
		if not supported then
			session.doubleJumpLeftGround = true
		elseif session.doubleJumpLeftGround then
			session.doubleJumpUsed = false
		end
	end
end

-- The server's own answer to "is this character on the ground" (audit M-004).
-- A grounded Humanoid label only counts with real geometry under the feet, so
-- a client can't fake a landing mid-air to refresh DoubleJump or clear its
-- fall height. The reverse lie (reporting Freefall while standing, to keep an
-- airborne speed cap or a WallLeap allowance alive) ends once that mismatch
-- has lasted a full speed-check window -- an honest takeoff or landing only
-- spends a few frames within `GroundQueryCastDistance` of the floor while
-- labelled airborne.
function Probes.IsGrounded(session: PlayerSession): boolean
	if not session.supported then
		return false
	end
	if isGrounded(session.humanoid:GetState()) then
		return true
	end
	local mismatchSince = session.supportedSince
	return mismatchSince ~= nil
		and os.clock() - mismatchSince >= MovementConstants.SpeedCheckIntervalSeconds
end

-- HardLanding fall-height tracking, server side (docs/MovementSystem.md §4.4
-- rework) -- mirrors the client's own Heartbeat-ordering comment exactly:
-- grow-only, and MUST run before `Mirror.PassiveTransitions` below in the
-- Heartbeat loop, for the identical same-frame-race reason. On the exact
-- landing Heartbeat, `context.grounded` has already flipped true by the time
-- `Mirror.PassiveTransitions` reads it to make the landing decision -- if this
-- reset `session.peakHeight` off that same read, `fallHeight` would already
-- be ~0 by the time `LandingResolution.Resolve` consults it moments later in
-- the SAME frame. Resetting is left entirely to the `fsm.changed` handler in
-- `createSession`, which only fires (synchronously, inside
-- `Mirror.PassiveTransitions`'s own `RequestTransition` call) AFTER the
-- landing decision has already consumed the real peak.
function Probes.UpdatePeakHeight(session: PlayerSession)
	local peakHeight = session.peakHeight
	if not peakHeight then
		return
	end
	local y = session.rootPart.Position.Y
	-- Water breaks a fall (swimming in scope, 2026-09-24): without this, a
	-- dive into water followed by climbing out onto land resolved the whole
	-- drop as one fall and forced HardLanding. Mirrors the client exactly.
	if
		session.humanoid:GetState() == Enum.HumanoidStateType.Swimming
		and SpatialQueries.IsInWater(session.rootPart.Position)
	then
		session.peakHeight = y
		return
	end
	session.peakHeight = math.max(peakHeight, y)
end

-- Slide's own ground-normal probe, server side (docs/MovementSystem.md §8/§4) -- throttled the same
-- way the client's own SlideState.Update is, just off `os.clock()` deltas rather than a `dt`
-- accumulator, since this file's Heartbeat loop doesn't carry a `dt` of its own (every other
-- server-side duration here is already `os.clock()`-timestamp-based, e.g.
-- `speedCheckAt`/`lastTransitionAt`). Cleared to nil the instant this session isn't mirrored into
-- Slide/SlideJump, so a stale read can't outlive the state it was measured for.
function Probes.UpdateSlideGroundQuery(
	session: PlayerSession,
	constants: EffectiveMovementConstants
)
	local current = session.fsm.current
	if current ~= MovementStates.Slide and current ~= MovementStates.SlideJump then
		session.slideGroundQuery = nil
		return
	end

	local now = os.clock()
	if now - session.slideGroundQueryAt < constants.SlideGroundRaycastThrottleSeconds then
		return
	end
	session.slideGroundQueryAt = now
	session.slideGroundQuery =
		SpatialQueries.QueryGround(session.rootPart, session.humanoid.Parent :: Instance)
end

-- Server's own side-cast probe (docs/MovementSystem.md §4.5/§8.4).
-- `force` bypasses the throttle for claim-time legality checks, which need
-- real current geometry (§3), not a stale Heartbeat-cadence sample (§9).
function Probes.UpdateWallRunQuery(session: PlayerSession, force: boolean?)
	if Probes.IsGrounded(session) then
		session.wallRunQuery = nil
		return
	end

	local now = os.clock()
	if
		not force
		and now - session.wallRunQueryAt < MovementConstants.WallRunQueryThrottleSeconds
	then
		return
	end
	session.wallRunQueryAt = now
	session.wallRunQuery =
		SpatialQueries.QueryWallRun(session.rootPart, session.humanoid.Parent :: Instance)
end

-- WallCling's own forward-cast probe, server side (docs/MovementSystem.md §4.6/§8.4) -- same
-- throttle-with-force-bypass shape as `Probes.UpdateWallRunQuery` above, off `WallClingRecheckInterval`
-- (the SAME non-tunable structural cadence the client's own sustain-check uses, kept fixed rather
-- than added to live tuning for the identical "server-only anti-cheat plumbing" reasoning
-- `WallRunQueryThrottleSeconds` already has). Continuous while airborne (not just while mirrored
-- into WallCling) so a claim evaluated the instant Space is pressed already has a fresh sample,
-- same reasoning `wallRunQuery` is kept continuously fresh rather than only probed on demand.
function Probes.UpdateWallClingQuery(session: PlayerSession, force: boolean?)
	if Probes.IsGrounded(session) then
		session.wallClingQuery = nil
		return
	end

	local now = os.clock()
	if
		not force
		and now - session.wallClingQueryAt < MovementConstants.WallClingRecheckInterval
	then
		return
	end
	session.wallClingQueryAt = now
	session.wallClingQuery =
		SpatialQueries.castClingWall(session.rootPart, session.humanoid.Parent :: Instance)
end

return Probes
