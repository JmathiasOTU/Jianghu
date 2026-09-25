--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)

local Network = require(script.Parent.Parent.Parent.Network.network)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local Probes = require(script.Parent.Probes)
local Context = require(script.Parent.Context)
local SpeedCaps = require(script.Parent.SpeedCaps)
local ClaimTiming = require(script.Parent.ClaimTiming)
local VerticalCeiling = require(script.Parent.VerticalCeiling)
local Mirror = require(script.Parent.Mirror)

type MovementContext = MovementTypes.MovementContext
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- ClaimTraversalMove (DoubleJump, WallRun, WallLeap, WallCling, WallBoost;
-- docs/MovementSystem.md §8.4): legality against the server's own mirror,
-- what each accepted move changes, and the claim buffer that retries a
-- claim which arrived before the positions supporting it.
local TraversalClaims = {}

-- WallRunState.Enter's one-time snap onto the cling distance moves the rig
-- along the wall normal, and a wall may tilt up to `WallDetectMaxUpDot`, so
-- the snap can lift the character slightly. Bounded by the farthest a
-- QueryWallRun hit can be from the root (cast reach plus sphere radius).
local function wallRunEntryMaxRise(constants: EffectiveMovementConstants): number
	local maxOffset = MovementConstants.WallRunSideCastDistance
		+ MovementConstants.WallRunSideCastRadius
	local maxNudge =
		math.max(constants.WallRunClingDistance, maxOffset - constants.WallRunClingDistance)
	return maxNudge * MovementConstants.WallDetectMaxUpDot
end

-- Shared acceptance bookkeeping for a WallRun entry landing -- whether it's
-- accepted on the FIRST attempt (`TraversalClaims.OnClaim`) or a BUFFERED retry
-- a few Heartbeats later (`TraversalClaims.RetryBuffered`, see
-- `WallRunClaimBufferSeconds`) -- one source of truth so the two paths can
-- never drift out of sync with each other. Deliberately does NOT set
-- `wallRunEntryNormal` here -- see `Mirror.PassiveTransitions`'s WallRun
-- branch for why that reference is anchored lazily off the Heartbeat loop's
-- own next throttled probe instead of whatever probe accepted the claim
-- (2026-09-19 fix for a spurious near-instant corner-exceeded force-exit).
local function acceptWallRunEntry(session: PlayerSession, constants: EffectiveMovementConstants)
	session.traversalEntryAt = os.clock()
	VerticalCeiling.Raise(session, wallRunEntryMaxRise(constants), 0)
	session.wallRunEntryNormal = nil
	session.wallRunEntryInstance = nil
	session.pendingWallRunClaimUntil = nil
end

-- Shared acceptance bookkeeping for a WallCling entry -- same two-caller
-- reasoning as `acceptWallRunEntry` above (docs/MovementSystem.md §8.4):
-- whether accepted on the first attempt or a buffered retry a few Heartbeats
-- later (`pendingWallClingClaimUntil`), one source of truth.
local function acceptWallClingEntry(session: PlayerSession, bufferedFor: number?)
	session.traversalEntryAt = os.clock()
	session.wallClingEnteredAt = os.clock() - (bufferedFor or 0)
	session.wallClingBoostUsed = false
	session.pendingWallClingClaimUntil = nil
	session.pendingWallBoostClaimUntil = nil
end

-- Shared acceptance bookkeeping for a DoubleJump, first attempt or a buffered
-- retry (`pendingDoubleJumpClaimUntil`).
local function acceptDoubleJump(session: PlayerSession, constants: EffectiveMovementConstants)
	session.traversalEntryAt = os.clock()
	session.doubleJumpUsed = true
	session.doubleJumpLeftGround = false
	session.pendingDoubleJumpClaimUntil = nil
	VerticalCeiling.Raise(
		session,
		TraversalMath.DoubleJumpMaxRise(
			constants.DoubleJumpForce,
			constants.DoubleJumpDecayDurationSeconds,
			Workspace.Gravity
		),
		TraversalMath.DoubleJumpTimeToApex(
			constants.DoubleJumpForce,
			constants.DoubleJumpDecayDurationSeconds,
			Workspace.Gravity
		)
	)
end

-- A DoubleJump/WallBoost claim the server finally refused (Studio only): the
-- client still performs the move, so the vertical ceiling will object next.
local function reportRejectedClaim(session: PlayerSession, claim: string)
	if not (DebugFlags.SPEED_SANITY_DEBUG_LOGGING or RunService:IsStudio()) then
		return
	end
	print(
		string.format(
			"[TraversalClaim] %s claim=%s REJECTED current=%s grounded=%s supported=%s doubleJumpUsed=%s humanoid=%s",
			session.player.Name,
			claim,
			tostring(session.fsm.current),
			tostring(Probes.IsGrounded(session)),
			tostring(session.supported),
			tostring(session.doubleJumpUsed),
			session.humanoid:GetState().Name
		)
	)
end

-- Shared acceptance bookkeeping for a WallBoost launch, first attempt or a
-- buffered retry (`pendingWallBoostClaimUntil`).
local function acceptWallBoost(session: PlayerSession, constants: EffectiveMovementConstants)
	session.wallClingBoostUsed = true
	session.wallBoostStartedAt = os.clock()
	session.pendingWallBoostClaimUntil = nil
	VerticalCeiling.Raise(
		session,
		TraversalMath.BallisticRise(constants.WallBoostUpwardForce, Workspace.Gravity),
		TraversalMath.TimeToApex(constants.WallBoostUpwardForce, Workspace.Gravity)
	)
end

-- Shared acceptance bookkeeping for a WallLeap launch -- same two-caller
-- reasoning as `acceptWallRunEntry` above.
local function acceptWallLeapLaunch(session: PlayerSession, context: MovementContext)
	local constants = context.constants
	session.traversalEntryAt = os.clock()

	-- The REAL fix for the "boost gets erased" playtest bug (2026-09-18):
	-- WallLeap's resulting speed doesn't decay -- Roblox applies no horizontal
	-- air drag, so the excess persists for the whole flight, and without this
	-- the flight would be measured against the ordinary Airborne cap and
	-- snapped back to the wall. Derived from server-known constants only
	-- (audit M-003): the old version added the client's replicated velocity,
	-- which a cheater could set to anything for one frame before the claim.
	-- `SpeedCaps.EffectiveMaxSpeed` consults it; cleared on landing (`fsm.changed`).
	session.airborneAllowanceExpiresAt = nil
	session.airborneAllowedSpeed = TraversalMath.WallLeapMaxHorizontalSpeed(
		constants.WallRunSpeed,
		constants.WallRunClingMaxCorrectionSpeed,
		constants.WallLeapBurstForce,
		constants.WallLeapPushForce
	)
	VerticalCeiling.Raise(
		session,
		TraversalMath.BallisticRise(constants.WallLeapUpwardForce, Workspace.Gravity),
		TraversalMath.TimeToApex(constants.WallLeapUpwardForce, Workspace.Gravity)
	)

	-- Mirrors the client's own synchronous two-step (WallLeapState.Enter):
	-- hand straight back to Airborne in the SAME call, matching the client's
	-- own FSM shape rather than leaving the mirror sitting in WallLeap for a
	-- Heartbeat. The server never re-derives or pushes its own velocity
	-- vector onto the character here (docs/MovementSystem.md §8.4) -- Roblox's own network
	-- ownership model keeps this player's physics client-authoritative, same
	-- as every other move in this file; this is legality plus the
	-- anti-exploit measures above, not a resimulation of the launch itself.
	--
	-- Wall-leap memory (docs/MovementSystem.md §4.6/§5): snapshotted BEFORE
	-- `wallRunEntryInstance` is cleared below, mirroring the client's own
	-- identical ordering in Movement/init.luau's `fsm.changed` handler.
	session.lastWallLeapWall = session.wallRunEntryInstance
	session.wallRunEntryNormal = nil
	session.wallRunEntryInstance = nil
	session.pendingWallLeapClaimUntil = nil
	session.fsm:RequestTransition(MovementStates.Airborne, context)
end

-- Heartbeat-driven follow-through for the claim-buffering set up in
-- `TraversalClaims.OnClaim` below (see `WallRunClaimBufferSeconds`'s own comment
-- for the full root-cause reasoning: a claim can arrive before the server's
-- own replicated state has caught up to support it, purely from ordinary
-- Roblox replication lag on a fast, continuous gesture like a double jump
-- chained straight into a wall run). Retries the exact SAME legality gate
-- `TraversalClaims.OnClaim` already ran -- `RequestTransition`'s real
-- `CanEnter`/topology check -- off whatever fresher server state THIS
-- Heartbeat has, every Heartbeat, until it succeeds or the buffer window
-- closes. Never invents new legality of its own.
function TraversalClaims.RetryBuffered(session: PlayerSession)
	local now = os.clock()
	local current = session.fsm.current

	-- Airborne is where a buffered WallRun/WallCling claim can land. DoubleJump
	-- keeps the buffer alive too (audit M-009): the server times DoubleJump ->
	-- Airborne from its own later accept, so a claim for the client's
	-- post-DoubleJump move can arrive while the mirror is still a few ms short
	-- of handing back to Airborne. Anything else (landed, moved into some other
	-- move entirely) means the gesture this claim wanted no longer applies.
	local airborneFamily = current == MovementStates.Airborne
		or current == MovementStates.DoubleJump

	if session.pendingWallRunClaimUntil then
		if now >= session.pendingWallRunClaimUntil or not airborneFamily then
			session.pendingWallRunClaimUntil = nil
		elseif current == MovementStates.Airborne then
			local context = Context.Build(session)
			local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)
			local waited = ClaimTiming.BufferedFor(session.pendingWallRunClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallRun, context) then
				acceptWallRunEntry(session, context.constants)
				ClaimTiming.CreditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- Landed, or otherwise left the WallRun/Airborne family entirely (e.g. the
	-- buffered WallRun claim above never itself landed) -- the leap this claim
	-- wanted no longer makes sense.
	if session.pendingWallLeapClaimUntil then
		current = session.fsm.current
		if
			now >= session.pendingWallLeapClaimUntil
			or (current ~= MovementStates.WallRun and current ~= MovementStates.Airborne)
		then
			session.pendingWallLeapClaimUntil = nil
		elseif current == MovementStates.WallRun then
			local context = Context.Build(session)
			local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)
			local waited = ClaimTiming.BufferedFor(session.pendingWallLeapClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallLeap, context) then
				acceptWallLeapLaunch(session, context)
				ClaimTiming.CreditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- Same buffered-retry shape as WallRun/WallLeap above (playtest bug
	-- 2026-09-19, see `pendingWallClingClaimUntil`'s own PlayerSession
	-- comment) -- retries the exact SAME `CanEnter[WallCling]`/topology gate
	-- `TraversalClaims.OnClaim` already ran, off whatever fresher
	-- `session.wallClingQuery` this Heartbeat's own `Probes.UpdateWallClingQuery`
	-- call already produced (that call runs earlier in the same Heartbeat,
	-- before `Mirror.PassiveTransitions`/this function -- see the Heartbeat
	-- loop's own ordering comment).
	if session.pendingWallClingClaimUntil then
		current = session.fsm.current
		if
			now >= session.pendingWallClingClaimUntil
			or (current ~= MovementStates.Airborne and current ~= MovementStates.DoubleJump)
		then
			session.pendingWallClingClaimUntil = nil
		elseif current == MovementStates.Airborne then
			local context = Context.Build(session)
			local waited = ClaimTiming.BufferedFor(session.pendingWallClingClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallCling, context) then
				acceptWallClingEntry(session, waited)
			end
		end
	end

	-- WallBoost's photo finish on `WallBoostMinClingSeconds` (see
	-- `pendingWallBoostClaimUntil`). Only meaningful while still clinging.
	if session.pendingWallBoostClaimUntil then
		current = session.fsm.current
		if now >= session.pendingWallBoostClaimUntil or current ~= MovementStates.WallCling then
			session.pendingWallBoostClaimUntil = nil
			reportRejectedClaim(session, "WallBoost")
		else
			local context = Context.Build(session)
			local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)
			local waited = ClaimTiming.BufferedFor(session.pendingWallBoostClaimUntil)
			if session.fsm:RequestTransition(MovementStates.WallBoost, context) then
				acceptWallBoost(session, context.constants)
				ClaimTiming.CreditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end

	-- DoubleJump waiting for the touchdown that refreshes it to show up in
	-- the position stream (see `pendingDoubleJumpClaimUntil`). The mirror may
	-- pass through a landing on the way, so only expiry abandons it.
	if session.pendingDoubleJumpClaimUntil then
		current = session.fsm.current
		if now >= session.pendingDoubleJumpClaimUntil then
			session.pendingDoubleJumpClaimUntil = nil
			reportRejectedClaim(session, "DoubleJump")
		elseif current == MovementStates.Airborne then
			local context = Context.Build(session)
			local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)
			local waited = ClaimTiming.BufferedFor(session.pendingDoubleJumpClaimUntil)
			if session.fsm:RequestTransition(MovementStates.DoubleJump, context) then
				acceptDoubleJump(session, context.constants)
				ClaimTiming.CreditClaimLatency(session, capBefore, context.constants, waited)
			end
		end
	end
end

-- The real exploit surface for the new traversal moves (docs/MovementSystem.md §7/§8;
-- docs/MovementSystem.md §8.4 for WallRun/WallLeap): a modified client could claim DoubleJump
-- without ever earning it (already airborne, air-jump not yet spent), or claim WallRun with no wall
-- nearby, or claim WallLeap without ever having actually earned WallRun. Legality is checked the
-- same way as every other claim in this file -- against this session's OWN mirrored FSM/context
-- (`CanEnter[WallRun]`, the SAME shared `StateRules` predicate the client evaluates, fed the
-- server's OWN `wallRunQuery`/`GetHorizontalVelocity`-equivalent read -- never a client-asserted
-- normal, tangent, or speed), never anything the client asserts. WallLeap needs no separate
-- predicate here beyond that shared check -- topology alone gates it (`StateRules.Transitions` only
-- has an edge INTO WallLeap from WallRun), so `RequestTransition` below already rejects the claim
-- outright unless this session is actually mirrored into WallRun, the same "you have to actually be
-- wall-running" legality WallLeapState's own client-side comment already explains.
function TraversalClaims.OnClaim(player: Player, claim: Network.ClaimableTraversalMove)
	local session = Sessions.ByPlayer[player]
	if not session then
		return
	end

	if not session.traversalRateLimiter:TryAcquire() then
		return
	end

	-- Root-cause fix, 2026-09-18 (real playtest bug: a "WallRun" claim
	-- arriving with `session.fsm.current` still `Run`, rejected purely on
	-- topology, even though the player had genuinely already left the
	-- ground) -- the mirror only advances passively once per server
	-- Heartbeat, off the LATEST replicated Humanoid state at the time that
	-- Heartbeat happens to run. A claim is a completely separate, asynchronous
	-- network arrival that can land BETWEEN two Heartbeats, before the one
	-- that would have caught the mirror up to `Airborne`. Rather than widen
	-- any tolerance to paper over that gap (docs/ARCHITECTURE.md §9), this
	-- re-runs the SAME passive-mirroring/wall-probe logic the Heartbeat loop
	-- already uses, right here, off the freshest replicated state available
	-- AT THE MOMENT the claim is actually processed. `Mirror.PassiveTransitions`
	-- is context-driven with no per-call side effects beyond the state it's
	-- already meant to reflect, so calling it an extra time between two
	-- regularly-scheduled Heartbeats only ever catches the mirror up SOONER,
	-- never differently.
	-- `force = true`: unlike `Mirror.PassiveTransitions`, `Probes.UpdateWallRunQuery`
	-- is internally throttled, so the plain call above wasn't actually fresh.
	-- `Probes.UpdateWallClingQuery` gets the identical forced-fresh treatment for the
	-- same reason (docs/MovementSystem.md §8.4).
	Probes.UpdateSupport(session)
	Probes.UpdateWallRunQuery(session, true)
	Probes.UpdateWallClingQuery(session, true)
	Mirror.PassiveTransitions(session)

	local claimedState = if claim == "DoubleJump"
		then MovementStates.DoubleJump
		elseif claim == "WallRun" then MovementStates.WallRun
		elseif claim == "WallLeap" then MovementStates.WallLeap
		elseif claim == "WallCling" then MovementStates.WallCling
		elseif claim == "WallBoost" then MovementStates.WallBoost
		else nil
	if not claimedState then
		return
	end

	local context = Context.Build(session)
	local constants = context.constants
	local capBefore = SpeedCaps.EffectiveMaxSpeed(session, constants)
	if session.fsm:RequestTransition(claimedState, context) then
		if claimedState == MovementStates.DoubleJump then
			acceptDoubleJump(session, constants)
		elseif claimedState == MovementStates.WallRun then
			acceptWallRunEntry(session, constants)
		elseif claimedState == MovementStates.WallLeap then
			acceptWallLeapLaunch(session, context)
		elseif claimedState == MovementStates.WallCling then
			acceptWallClingEntry(session)
		elseif claimedState == MovementStates.WallBoost then
			acceptWallBoost(session, constants)
		end
		ClaimTiming.CreditClaimLatency(session, capBefore, constants)
		return
	end

	-- Claim-buffering (2026-09-19 playtest fix -- see `WallRunClaimBufferSeconds`'s
	-- own comment for the full root-cause reasoning): a rejection here can
	-- simply mean the server's own replicated state hasn't caught up YET to
	-- support a claim the player genuinely, legitimately just earned. Buffer
	-- it and let `TraversalClaims.RetryBuffered` keep re-checking the SAME
	-- legality gate every Heartbeat until it either succeeds or this window
	-- closes -- a claim that's actually illegal (no wall anywhere, standing
	-- still, etc.) gets buffered exactly the same way, but simply never
	-- succeeds during that window, since the real `CanEnter`/topology check
	-- keeps running against it unchanged.
	if claimedState == MovementStates.WallRun then
		session.pendingWallRunClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.WallLeap then
		session.pendingWallLeapClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.WallCling then
		-- Same root cause as WallRun's own buffering above (playtest bug
		-- 2026-09-19): a rejection can simply mean the server's own
		-- replicated position/CFrame hasn't caught up yet to a wall the
		-- player only just moved into range of. Reuses
		-- `WallRunClaimBufferSeconds` rather than a second, unmeasured window
		-- -- see the field's own PlayerSession comment.
		session.pendingWallClingClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
	elseif claimedState == MovementStates.DoubleJump then
		session.pendingDoubleJumpClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
		return
	elseif
		claimedState == MovementStates.WallBoost
		and session.fsm.current == MovementStates.WallCling
	then
		-- Still clinging, so the likely reason is the minimum cling time
		-- landing a few ms short on this side (see `pendingWallBoostClaimUntil`).
		session.pendingWallBoostClaimUntil = os.clock()
			+ MovementConstants.WallRunClaimBufferSeconds
		return
	end

	-- WallBoost outside a cling isn't buffered (DoubleJump and in-cling
	-- WallBoost returned above), so this rejection is final.
	if claimedState == MovementStates.WallBoost then
		reportRejectedClaim(session, claim)
	end

	if
		DebugFlags.WALL_TRAVERSAL_DEBUG_LOGGING
		and (claimedState == MovementStates.WallRun or claimedState == MovementStates.WallLeap)
	then
		print(
			string.format(
				"[WallTraversal] %s claim=%s REJECTED current=%s wallRunQuery=%s",
				player.Name,
				claim,
				tostring(session.fsm.current),
				tostring(context.wallRunQuery ~= nil)
			)
		)
	end
end

return TraversalClaims
