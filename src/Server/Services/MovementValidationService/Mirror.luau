--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local StateRules = require(ReplicatedStorage.Shared.Movement.StateRules)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local LandingResolution = require(ReplicatedStorage.Shared.Movement.LandingResolution)

local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)
local Violations = require(script.Parent.Violations)
local Context = require(script.Parent.Context)
local SpeedCaps = require(script.Parent.SpeedCaps)
local SpeedCheck = require(script.Parent.SpeedCheck)
local ClaimTiming = require(script.Parent.ClaimTiming)
local VerticalCeiling = require(script.Parent.VerticalCeiling)

type PlayerSession = Sessions.PlayerSession

-- The server's passive mirror (docs/MovementSystem.md §8.1): every
-- transition it decides on its own each Heartbeat, from replicated state
-- and its own probes, plus the force-exits that keep wall states and
-- HardLanding honest.
local Mirror = {}

-- Idle/Walk/Airborne need no remote (Humanoid state already replicates), so the
-- mirror follows them passively here. Run/Sprint are only ever *entered* via the
-- explicit claim below -- this never attempts either as a target, so an unclaimed
-- client can never end up mirrored as Run/Sprint no matter what MoveDirection says.
-- Sprint's demotion back to Run IS handled here, on the server's own initiative
-- (see docs/MovementSystem.md §8) -- it doesn't wait for the client to re-claim Run.
function Mirror.PassiveTransitions(session: PlayerSession)
	local context = Context.Build(session)
	local current = session.fsm.current

	-- Slide -> SlideJump -> Airborne (docs/MovementSystem.md §4.2): reactive off the
	-- same already-replicated Humanoid state Airborne's own entry already
	-- reads (`context.jumping`) -- no claim needed, same reasoning as
	-- Airborne itself. Checked before every other branch below since
	-- `context.grounded` has ALREADY flipped false by the time `jumping`
	-- reads true (both come from the same single `Humanoid:GetState()`), so
	-- the generic "not grounded -> Airborne" branch further down would
	-- otherwise catch this first and skip the boost entirely.
	if current == MovementStates.Slide and context.jumping then
		if session.fsm:RequestTransition(MovementStates.SlideJump, context) then
			-- Crouch-lock (SlideJump landing fix): armed the instant this
			-- session's mirror enters SlideJump, same edge the client's own
			-- `crouchSuppressed` arms on -- see the PlayerSession field comment.
			session.crouchSuppressed = true
			-- SlideJumpState.Enter launches at up to `SpeedCaps.SlideCeiling`, above the
			-- Airborne cap, and nothing slows it in the air, so the flight
			-- keeps that allowance until it ends (2026-09-24 fix: it used to
			-- get only the 1s landing grace, which a long jump outlasts).
			-- Set before the hand-off so the landing grace snapshot sees it.
			session.airborneAllowedSpeed = SpeedCaps.SlideCeiling(context.constants)
			session.airborneAllowanceExpiresAt = nil
			-- SlideJumpState launches upward at SlideJumpUpwardSpeed, faster
			-- than the Humanoid's JumpPower. Still on the ground as far as the
			-- position stream shows: the anchors up to takeoff use it. Already
			-- off the ground: raise the ceiling from that takeoff instead.
			local launchSpeed = MovementConstants.SlideJumpUpwardSpeed
			if session.supported then
				session.groundLaunchSpeed = launchSpeed
			else
				local gravity = Workspace.Gravity
				local jumpSpeed = context.constants.JumpPower + session.floorRiseSpeed
				VerticalCeiling.Raise(
					session,
					TraversalMath.BallisticRise(launchSpeed, gravity)
						- TraversalMath.BallisticRise(jumpSpeed, gravity),
					math.max(
						session.verticalAnchorAt
							+ TraversalMath.TimeToApex(launchSpeed, gravity)
							- os.clock(),
						0
					)
				)
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	if current == MovementStates.Airborne then
		if context.grounded then
			-- Landing while Ctrl is held goes to the crouch-variant instead of
			-- Idle/Walk (docs/MovementSystem.md §4.2) -- a single-tick decision, same
			-- as AirborneState.Update's own client-side landing logic.
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				-- DoubleJump reset (docs/MovementSystem.md §5): mirrors the
				-- client's own reset on the identical "landed" edge.
				session.doubleJumpUsed = false
				-- Landing-resume fix: consumed the instant a landing actually
				-- resolves, same edge as the doubleJumpUsed reset just above.
				session.preAirborneLocomotion = nil
			end
		end
		return
	end

	-- DoubleJump hands itself back to Airborne once its own decay curve
	-- finishes (docs/MovementSystem.md §5/§8), on the server's own initiative,
	-- off its own entry-snapshot timestamp, never anything the client asserts
	-- about when its impulse "should" end. Checked BEFORE the generic
	-- "not grounded -> Airborne" fallback below, which would otherwise fire
	-- every single Heartbeat while DoubleJump is active (it's airborne by
	-- definition) and immediately evict the mirror out of DoubleJump the
	-- instant the claim was accepted.
	--
	-- Landing mid-impulse is its OWN branch, not folded into "-> Airborne":
	-- `Airborne.CanEnter` requires `not grounded`, already false by the
	-- instant `context.grounded` reads true here, so that transition would
	-- simply be rejected and leave the mirror stuck in DoubleJump -- resolves
	-- straight to the real grounded target instead, same fix as the client's
	-- own DoubleJumpState.Update.
	if current == MovementStates.DoubleJump then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				-- Landing-resume fix: same consume-on-landing edge as the
				-- Airborne branch above -- `preAirborneLocomotion` survives the
				-- Airborne -> DoubleJump hop untouched (see where it's set,
				-- below), so this mid-impulse landing still needs to clear it.
				session.preAirborneLocomotion = nil
			end
			return
		end

		local elapsed = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
		if elapsed >= context.constants.DoubleJumpDecayDurationSeconds then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallRun's anti-exploit backbone (docs/MovementSystem.md §8.4)
	-- -- runs every server Heartbeat this session is mirrored into WallRun,
	-- off the session's OWN `wallRunQuery`/entry snapshot, never anything the
	-- client claims or reports. A client that stops sending packets, or lies
	-- about still being on a wall, gets force-mirrored back to Airborne the
	-- instant the server's own shapecast says the wall is gone, the corner
	-- budget is exceeded, or the duration cap hits -- independent of what the
	-- client-side FSM thinks is happening. Landing mid-run is its own branch
	-- first, same "resolve straight to the real grounded target, don't fall
	-- through to a rejected -> Airborne attempt" shape DoubleJump's own
	-- branch above already established.
	if current == MovementStates.WallRun then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local query = session.wallRunQuery

		-- Lazy-anchor the corner-deviation reference (2026-09-19 playtest fix:
		-- a real force-exit was observed ~0.12s after a legitimately accepted
		-- entry, `angleExceeded=true` on the very first post-entry query).
		-- `TraversalClaims.OnClaim` locks `wallRunEntryNormal` off a FORCED probe
		-- taken at the exact claim instant -- but that probe reads
		-- `session.rootPart.CFrame`, and CFrame (rotation), not just position,
		-- replicates from the client with its own lag independent of
		-- `WallRunSideCastDistance`'s already-documented position lag. A
		-- player's rig is still finishing its turn to face along the wall
		-- tangent at the instant the claim lands, so the FIRST cast can read a
		-- glancing, not-yet-settled normal; the very next throttled query
		-- (~`WallRunQueryThrottleSeconds` later, once rotation has caught up)
		-- then reads the REAL normal, which can easily be > the corner budget
		-- away from that first noisy sample -- a false corner, not a real one.
		-- Anchoring instead off the first probe taken AFTER the accept gives
		-- rotation a beat to settle before anything gets compared against it.
		-- The cached query at the accept is the claim-time probe itself, so it
		-- must be skipped explicitly (2026-09-25 capture: wrapping round a wall
		-- end, that probe still saw the face just left, and the first real
		-- probe force-exited at `elapsed=0.10` with `angleExceeded`). This
		-- doesn't relax the anti-exploit check -- the SAME angle/duration
		-- budget still applies from here on -- it only fixes which sample the
		-- budget is measured against.
		if not session.wallRunEntryNormal then
			local enteredAt = session.traversalEntryAt or session.lastTransitionAt
			if session.wallRunQueryAt <= enteredAt then
				return
			end
			if query then
				session.wallRunEntryNormal = query.normal
				-- Same lazy-anchor timing as the normal above (docs/MovementSystem.md §4.6/§5) --
				-- captured here, not at claim time, so `lastWallLeapWall` (set off this when a leap
				-- is accepted) agrees with whichever wall the corner-deviation check itself is
				-- actually anchored to.
				session.wallRunEntryInstance = query.instance
				return
			end
			-- The first post-entry probe found no wall: fall through to the
			-- lost-wall exit below rather than waiting unanchored, which used to
			-- skip the wall and duration checks (and hold the vertical ceiling)
			-- for as long as no wall showed up.
		end

		local angleExceeded = query
			and TraversalMath.AngleBetween(query.normal, session.wallRunEntryNormal :: Vector3)
				> context.constants.WallRunMaxNormalDeviationDegrees
		local durationExceeded = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
			>= context.constants.WallRunMaxDurationSeconds

		if not query or angleExceeded or durationExceeded then
			if DebugFlags.WALL_TRAVERSAL_DEBUG_LOGGING then
				print(
					string.format(
						"[WallTraversal] %s WallRun force-exit: query=%s entryNormal=%s angleExceeded=%s durationExceeded=%s elapsed=%.2f",
						session.player.Name,
						tostring(query ~= nil),
						tostring(session.wallRunEntryNormal ~= nil),
						tostring(angleExceeded == true),
						tostring(durationExceeded),
						os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
					)
				)
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallCling's anti-exploit backbone (docs/MovementSystem.md §8.4)
	-- -- duration cap (reuses the generic `traversalEntryAt`, same as
	-- DoubleJump/WallRun, since this check only ever matters while still
	-- mirrored into WallCling) plus an independent wall-presence recheck off
	-- this session's OWN throttled probe (`Probes.UpdateWallClingQuery`). The plan's
	-- own §11.3 argued the speed ceiling alone (WallClingSpeedCeiling = 0)
	-- was enough and skipped a periodic re-cast entirely -- but
	-- `SpeedCheck.Enforce` only ever measures HORIZONTAL (X/Z) delta, so a
	-- player who legitimately drops and falls straight down would never trip
	-- it, leaving the mirror stuck in WallCling (via `next == self.current`
	-- in StateMachine:CanTransition) for up to the full duration cap and
	-- rejecting a legitimate re-cling in the meantime -- the identical
	-- mirror-desync failure mode WallRun's own sustain check (just above)
	-- already exists to prevent. Landing mid-cling is its own branch first,
	-- same "resolve straight to the real grounded target" shape every other
	-- airborne-family state here already establishes.
	if current == MovementStates.WallCling then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local durationExceeded = os.clock() - (session.traversalEntryAt or session.lastTransitionAt)
			>= context.constants.WallClingMaxDuration

		if not session.wallClingQuery or durationExceeded then
			-- Only Timeout applies a lockout here (docs/MovementSystem.md §4.6's exit-reason table)
			-- -- a server-detected WallLost leaves `wallClingLockoutUntil` untouched, same "none"
			-- the client's own WallLost branch already applies.
			if durationExceeded then
				session.wallClingLockoutUntil = os.clock()
					+ context.constants.WallClingTimeoutLockout
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- WallBoost (docs/MovementSystem.md §8.4): a short, fixed window off
	-- its OWN dedicated `wallBoostStartedAt` (not the generic
	-- `traversalEntryAt` -- see that field's own PlayerSession comment for
	-- why), hands back to Airborne once it elapses. No further legality to
	-- check while inside it -- `SpeedCaps.EffectiveMaxSpeed`'s own envelope formula is
	-- what actually keeps this window honest, not a corner/wall recheck.
	if current == MovementStates.WallBoost then
		if context.grounded then
			if session.fsm:RequestTransition(LandingResolution.Resolve(context), context) then
				session.doubleJumpUsed = false
				session.preAirborneLocomotion = nil
			end
			return
		end

		local startedAt = session.wallBoostStartedAt or session.lastTransitionAt
		if os.clock() - startedAt >= context.constants.WallBoostStateDuration then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
		end
		return
	end

	-- HardLanding (docs/MovementSystem.md §4.4 rework): mirrors `HardLandingState.
	-- Update` client-side exactly -- losing the ground mid-lock is involuntary
	-- and takes priority over the lock timer (nothing left to lock the player
	-- TO); otherwise holds until this session's own `hardLandingLockUntil`
	-- (set server-side, off this session's own effective tuning, on the
	-- `fsm.changed` edge into HardLanding -- never anything the client
	-- claims), then re-resolves the SAME landing decision Airborne/DoubleJump
	-- use. `context.fallHeight` is already nil by this point (cleared the
	-- instant HardLanding was entered), so this always resolves to an
	-- ordinary grounded target, never back into HardLanding again.
	--
	-- Server-enforced (audit M-010, designer answer 2026-09-24): while the
	-- lock runs, only the server's OWN support probe can end it -- the
	-- client's Humanoid label is ignored. Losing support after rising more
	-- than the probe's reach above the lock position can only be a jump (a
	-- vanishing floor drops the character, never lifts it), so it is a
	-- violation and the character is put back where the lock began.
	if current == MovementStates.HardLanding then
		local lockUntil = session.hardLandingLockUntil
		local lockPosition = session.hardLandingLockPosition
		if lockUntil and lockPosition and os.clock() < lockUntil then
			if session.supported then
				return
			end
			local rise = session.rootPart.Position.Y - lockPosition.Y
			if
				rise
				> MovementConstants.GroundQueryCastDistance
					- MovementConstants.RigRootHeightAboveFeet
			then
				-- The client's lock started when IT landed; the server only
				-- sees that landing once the position and Humanoid state have
				-- replicated, so its own lock ends later by up to that delay.
				-- A jump in the lock's last `ClaimTiming.ClaimLagSeconds` is the client's
				-- lock ending first, not an escape (2026-09-24 playtest:
				-- jumping the moment a hard landing ended snapped players back).
				local remaining = lockUntil - os.clock()
				if remaining <= ClaimTiming.ClaimLagSeconds(session) then
					session.fsm:RequestTransition(MovementStates.Airborne, context)
					return
				end
				Violations.Report(
					session,
					"HardLandingEscape",
					{ rise = rise, lockRemaining = remaining }
				)
				SpeedCheck.CorrectToPosition(session, lockPosition)
				return
			end
			session.fsm:RequestTransition(MovementStates.Airborne, context)
			return
		end
		if not context.grounded then
			session.fsm:RequestTransition(MovementStates.Airborne, context)
			return
		end
		session.fsm:RequestTransition(LandingResolution.Resolve(context), context)
		return
	end

	if not context.grounded then
		-- Landing-resume fix: `current` is whatever grounded state this
		-- session's mirror is about to leave -- the same "previous" the
		-- client's own fsm.changed handler reads, just sourced before the
		-- transition instead of from the edge's own callback args.
		if current == MovementStates.Run or current == MovementStates.Sprint then
			session.preAirborneLocomotion = current
		end
		session.fsm:RequestTransition(MovementStates.Airborne, context)
		return
	end

	if current == MovementStates.Slide then
		-- Decay estimate (docs/MovementSystem.md §4.2): the server never tracks
		-- Slide's exact real velocity -- its speed cap is the flat
		-- `SpeedCaps.SlideCeiling` (see `maxSpeedForState`), not a simulated curve --
		-- this only estimates WHEN the client's own decay reaches CrouchSpeed,
		-- timed from the fastest entry the client could have had
		-- (`slideEntrySpeed`). It used to use the bare Run/Sprint tier, which
		-- left out SlideEntrySpeedMultiplier: the mirror left Slide up to 0.5s
		-- before the client did, and a slide jump in that gap reached the
		-- server as a plain jump capped at SprintSpeed (2026-09-24 fix). A
		-- slower real entry ends the client's slide first; the mirror follows
		-- once its own estimate runs out, which only ever keeps the higher
		-- Slide cap a little longer.
		local entrySpeed = session.slideEntrySpeed
		local elapsed = os.clock() - session.lastTransitionAt
		local decayedSpeed = math.max(
			context.constants.CrouchSpeed,
			entrySpeed - context.constants.SlideDecayRate * elapsed
		)
		if decayedSpeed <= context.constants.CrouchSpeed then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.CrouchWalk
					else MovementStates.CrouchIdle,
				context
			)
		end
		return
	end

	if current == MovementStates.CrouchIdle then
		if not context.crouchHeld then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.Walk
					else MovementStates.Idle,
				context
			)
		elseif StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.CrouchWalk, context)
		end
		return
	end

	if current == MovementStates.CrouchWalk then
		if not context.crouchHeld then
			session.fsm:RequestTransition(
				if StateRules.HasMoveInput(context)
					then MovementStates.Walk
					else MovementStates.Idle,
				context
			)
		elseif not StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.CrouchIdle, context)
		end
		return
	end

	-- From here on, `current` is one of Idle/Walk/Run/Sprint -- Crouch/Slide
	-- takes priority over the ordinary family the instant Ctrl is held,
	-- exactly the same priority every client state module's own Update
	-- already gives it (docs/MovementSystem.md §4.2). CrouchWalk is gated behind
	-- CrouchIdle (mirrors IdleState/WalkState client-side), so Idle/Walk
	-- always land in CrouchIdle first, even with move input already held --
	-- the CrouchIdle branch above re-checks input the very next tick.
	if context.crouchHeld then
		if current == MovementStates.Run or current == MovementStates.Sprint then
			session.fsm:RequestTransition(MovementStates.Slide, context)
			return
		end
		session.fsm:RequestTransition(MovementStates.CrouchIdle, context)
		return
	end

	if current == MovementStates.Idle then
		if StateRules.HasMoveInput(context) then
			session.fsm:RequestTransition(MovementStates.Walk, context)
		end
	elseif not StateRules.HasMoveInput(context) then
		-- Walk, Run, or Sprint with no input left: drop straight to Idle.
		session.fsm:RequestTransition(MovementStates.Idle, context)
	elseif
		current == MovementStates.Sprint
		and session.cameraLocked
		and not context.moveIntent.forward
	then
		-- Same demotion condition as SprintState.Update client-side (backpedal or
		-- pure strafe drops Sprint), enforced independently of whether a modified
		-- client ever sends the matching reclaim.
		--
		-- Gated on a locked camera (found during the 2026-09-13
		-- rubber-banding investigation): `classifyMoveIntent` approximates "is this
		-- forward" from `rootPart.CFrame.LookVector` vs. `MoveDirection`, but
		-- `FacingController`'s own fix (§4, also 2026-09-13) established that
		-- facing *deliberately* lags MoveDirection whenever `AutoRotate` is true
		-- (unlocked camera) -- Roblox's own ground controller turns the character
		-- to catch up rather than snapping. A player who simply looks around while
		-- holding forward, unlocked, can swing MoveDirection well ahead of facing
		-- for a few frames -- comfortably past this check's deadzone -- with zero
		-- backward/strafe input at all. That's not a desync to correct for, it's
		-- this proxy being the wrong signal in that mode: strafe-style facing
		-- decoupling (and with it, a meaningful "backpedal relative to facing")
		-- only applies while locked in the first place (see this doc's intro).
		-- The lock state comes from the client's CameraLocked/CameraUnlocked
		-- level claims (audit M-020): `AutoRotate`, which this used to read, is
		-- written client-side and never replicated, so this branch never ran.
		--
		-- This narrows, rather than removes, server enforcement while unlocked:
		-- the "no input at all -> Idle" branch above and `SpeedCheck.Enforce`'s
		-- speed cap both still apply unconditionally. The one residual gap is
		-- narrow and low-severity -- a modified client could hold Sprint's speed
		-- cap (not Run's) while moving backward, unlocked, without ever
		-- backpedal-demoting -- documented in docs/MovementSystem.md §8 rather than
		-- silently accepted.
		if session.fsm:RequestTransition(MovementStates.Run, context) then
			-- RunState.Enter resets the client's own dwell clock on every entry
			-- into Run, this demotion included -- without this reset, a client
			-- that never re-sends the "Run" claim (bug found 2026-09-13: a
			-- malicious one has no reason to) would keep the ORIGINAL
			-- runEnteredAt from before Sprint, so re-claiming "Sprint" a moment
			-- later would instantly pass the dwell check off stale elapsed time,
			-- instead of requiring a fresh 3-second Run streak like a legitimate
			-- client always does.
			session.runEnteredAt = os.clock()
		end
	end
end

return Mirror
