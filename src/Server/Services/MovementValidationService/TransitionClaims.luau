--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

local Network = require(script.Parent.Parent.Parent.Network.network)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local Context = require(script.Parent.Context)
local SpeedCaps = require(script.Parent.SpeedCaps)
local ClaimTiming = require(script.Parent.ClaimTiming)

type PlayerSession = Sessions.PlayerSession

-- RequestMovementTransition (docs/MovementSystem.md §7-§8.1): Run and
-- Sprint claims against the server's own dwell clock, the crouch and
-- camera-lock level claims, and Sprint's claim buffer.
local TransitionClaims = {}

-- Sprint's own buffered retry (2026-09-21 "flagged switching Run->Sprint"
-- investigation, see `pendingSprintClaimUntil`'s own PlayerSession comment
-- for the full root-cause reasoning) -- same shape as
-- `TraversalClaims.RetryBuffered` above, kept as its own function rather than
-- folded in since Run/Sprint use the dwell-timestamp model, not the
-- resimulation model every claim in that function shares. Retries the exact
-- SAME `CanEnter[Sprint]` dwell check `TransitionClaims.OnRequest` already
-- ran, off whatever fresher `runDuration` THIS Heartbeat's `Context.Build`
-- produces, every Heartbeat, until it succeeds or the buffer window closes.
-- Never invents new legality of its own -- a still-too-early dwell simply
-- keeps failing `RequestTransition` the same way it would from a fresh claim.
function TransitionClaims.RetryBufferedSprint(session: PlayerSession)
	if not session.pendingSprintClaimUntil then
		return
	end

	local now = os.clock()
	if now >= session.pendingSprintClaimUntil then
		session.pendingSprintClaimUntil = nil
		return
	end

	if session.fsm.current ~= MovementStates.Run then
		-- Demoted, landed into a different tier, or otherwise left Run
		-- entirely since the buffer was armed -- the Sprint this claim wanted
		-- no longer applies.
		session.pendingSprintClaimUntil = nil
		return
	end

	local context = Context.Build(session)
	if not context.grounded then
		session.pendingSprintClaimUntil = nil
		return
	end

	local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)
	local waited = ClaimTiming.BufferedFor(session.pendingSprintClaimUntil)
	if session.fsm:RequestTransition(MovementStates.Sprint, context) then
		session.pendingSprintClaimUntil = nil
		ClaimTiming.CreditClaimLatency(session, capBefore, context.constants, waited)
	end
end

-- The real exploit surface (see docs/ARCHITECTURE.md §5): a modified client could
-- claim Sprint without ever earning it. Legality is checked against this session's
-- OWN runEnteredAt timestamp -- never anything the client sends -- same
-- lag-compensation principle as parry (§4), applied to a locomotion transition.
function TransitionClaims.OnRequest(player: Player, claim: Network.ClaimableMovementState)
	local session = Sessions.ByPlayer[player]
	if not session then
		return
	end

	-- Crouch/Slide (docs/MovementSystem.md §4.2): these two DON'T name an FSM target
	-- state, unlike every other claim here -- they only set/clear this
	-- session's own `crouchHeld` flag. No dwell timer, no FSM attempt at all;
	-- `Mirror.PassiveTransitions` (next Heartbeat) is what turns this into an
	-- actual transition, the same way it already turns `moveIntent` into
	-- Idle<->Walk. Resent by the client as a level every second (audit M-006),
	-- so both are idempotent and gated by their own limiter.
	if claim == "CameraLocked" or claim == "CameraUnlocked" then
		if session.levelRateLimiter:TryAcquire() then
			session.cameraLocked = claim == "CameraLocked"
		end
		return
	end

	if claim == "CrouchDown" or claim == "CrouchUp" then
		if not session.levelRateLimiter:TryAcquire() then
			return
		end
		if claim == "CrouchDown" then
			session.crouchHeld = true
		else
			session.crouchHeld = false
			-- Crouch-lock re-arm (SlideJump landing fix): mirrors the client's
			-- own `crouchSuppressed` clear, which happens whenever Ctrl is up --
			-- a CrouchUp level report IS that fact server-side.
			session.crouchSuppressed = false
		end
		return
	end

	if not session.rateLimiter:TryAcquire() then
		if DebugFlags.SPEED_SANITY_DEBUG_LOGGING then
			-- Confirms/rules out the rate limiter itself as a cause of dropped
			-- legitimate claims (docs/MovementSystem.md §8) -- 5/second should never be
			-- reachable by normal play (one claim per Run/Sprint entry), so this
			-- firing during an ordinary playtest would point at the limiter, not
			-- at SpeedCheck.Enforce, as the actual bug.
			print(string.format("[SpeedSanity] %s RATE LIMITED claim=%s", player.Name, claim))
		end
		return
	end

	local claimedState = if claim == "Run" then MovementStates.Run else MovementStates.Sprint
	local context = Context.Build(session)
	local capBefore = SpeedCaps.EffectiveMaxSpeed(session, context.constants)

	if session.fsm:RequestTransition(claimedState, context) then
		ClaimTiming.CreditClaimLatency(session, capBefore, context.constants)
		-- A fresh accept on either claim invalidates any earlier buffered
		-- Sprint retry (2026-09-21 investigation, see `pendingSprintClaimUntil`'s
		-- own PlayerSession comment): a new "Run" claim starts a brand new
		-- dwell cycle the old buffer knows nothing about, and a direct "Sprint"
		-- accept here means there's nothing left to retry.
		session.pendingSprintClaimUntil = nil

		if claimedState == MovementStates.Run then
			-- Backdated by half this player's measured RTT (docs/MovementSystem.md §8,
			-- fixed 2026-09-14) -- the claim carrying this instant already reached
			-- the server late, so stamping raw receipt time skews the server's
			-- dwell clock later than the client's own, which used to land a
			-- legitimate first Sprint claim right on the 3s boundary (near-even
			-- odds of rejection from jitter alone) instead of comfortably past it.
			local ping = player:GetNetworkPing()
			-- Guards `GetNetworkPing()` returning 0 (no sample yet -- e.g. this is
			-- the very first claim right after spawn) or an implausibly large
			-- reading: capped at half of `SprintThresholdSeconds` so a bad reading
			-- here can never backdate far enough to let Sprint be claimed with
			-- little to no real Run dwell.
			local backdateSeconds = if ping > 0
				then math.min(ping / 2, context.constants.SprintThresholdSeconds / 2)
				else 0
			session.runEnteredAt = os.clock() - backdateSeconds
		elseif DebugFlags.SPEED_SANITY_DEBUG_LOGGING and context.runDuration then
			-- The server only ever sees "Sprint" claimed once its OWN runEnteredAt
			-- says the dwell is satisfied, so this is never negative -- it's purely
			-- how much the client's local dwell clock (which crossed the 3s
			-- threshold first, then had to round-trip this claim over the network)
			-- had already run past 3s by the time the server processed it. A
			-- consistently large number here is the claim-round-trip lag docs/MovementSystem.md §8
			-- asks to rule in or out as a rubber-banding cause.
			print(
				string.format(
					"[SpeedSanity] %s Sprint claim accepted, dwell overshoot=%.3fs",
					player.Name,
					(context.runDuration :: number) - context.constants.SprintThresholdSeconds
				)
			)
		end
		return
	end

	if DebugFlags.SPEED_SANITY_DEBUG_LOGGING then
		-- Rejection path had NO visibility at all before this (2026-09-21
		-- "flagged switching Run->Sprint" investigation) -- the accept branch
		-- above already prints dwell overshoot, but a claim that fails
		-- `CanEnter`/topology here silently returns, leaving the server's
		-- mirror stuck one tier behind whatever the client already predicted
		-- and entered. That mismatch is what feeds `SpeedCaps.EffectiveMaxSpeed` (keyed
		-- off `session.fsm.current`, never the client's state) a stale, lower
		-- cap, which is what `SpeedCheck.Enforce` then flags every
		-- `SpeedCheckIntervalSeconds` until the next resync claim
		-- (Movement/init.luau's `CLAIM_RESYNC_INTERVAL_SECONDS`) gets through --
		-- this print is what actually distinguishes "the dwell-backdate
		-- undercompensated real latency" from every other way this claim could
		-- have been rejected (already in that state, wrong topology edge, not
		-- grounded), instead of guessing which one to fix.
		print(
			string.format(
				"[SpeedSanity] %s claim=%s REJECTED current=%s grounded=%s runDuration=%s threshold=%.2f preAirborne=%s",
				player.Name,
				claim,
				tostring(session.fsm.current),
				tostring(context.grounded),
				if context.runDuration
					then string.format("%.3f", context.runDuration :: number)
					else "nil",
				context.constants.SprintThresholdSeconds,
				tostring(context.preAirborneLocomotion)
			)
		)
	end

	-- Buffered Sprint retry (2026-09-21 investigation): the rejection logging
	-- above, run against a real playtest, showed every rejected "Sprint" claim
	-- landing with `runDuration` within single milliseconds of `threshold`
	-- while already grounded and mirrored into Run -- the client fires this
	-- claim the INSTANT its own local dwell clock crosses 3s, and the server's
	-- independently-tracked (if backdated) clock has to have ALSO already
	-- crossed by the time this arrives. That's an inherent photo finish no
	-- amount of backdate tuning removes -- the two machines' Heartbeat/frame
	-- boundaries simply don't align. Left unhandled, the session sat capped at
	-- RunSpeed until the client's next periodic resync claim
	-- (`CLAIM_RESYNC_INTERVAL_SECONDS`, a full second away), during which
	-- `SpeedCheck.Enforce` fired real corrections against real players -- the
	-- exact rubber-banding this investigation exists to fix. Buffering it here
	-- follows the SAME `pendingWallRunClaimUntil`/`TraversalClaims.RetryBuffered`
	-- idiom `TraversalClaims.OnClaim` already established for this identical class
	-- of "claim arrived a beat before the server could agree" race, reusing
	-- `WallRunClaimBufferSeconds` rather than a second, unmeasured window (the
	-- same reuse `pendingWallClingClaimUntil` already justifies for the
	-- identical reason). Only armed when grounded-and-Run is the ONLY thing
	-- that could have failed `CanEnter[Sprint]` -- any other rejection (still
	-- airborne, wrong topology edge entirely) has nothing to retry toward.
	if
		claimedState == MovementStates.Sprint
		and session.fsm.current == MovementStates.Run
		and context.grounded
	then
		session.pendingSprintClaimUntil = os.clock() + MovementConstants.WallRunClaimBufferSeconds
	end
end

return TransitionClaims
