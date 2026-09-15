opt server_output = "src/Server/Network/network.luau"
opt client_output = "src/Client/Network/network.luau"
opt casing = "PascalCase"
opt write_checks = true

-- Real events land here as movement/combat systems are built.
-- Every player-initiated combat/movement remote must set a rate limit
-- per docs/ARCHITECTURE.md §10 — see Events docs: https://zap.redblox.dev/config/events

-- Movement (Phase 1) --------------------------------------------------------
--
-- Idle, Walk, and Airborne need no remote: Humanoid state (WalkSpeed, jump, fall)
-- already replicates natively, and MovementValidationService mirrors those
-- transitions passively from that replication.
--
-- Run and Sprint are earned transitions (double-tap dwell / 3s continuous-Run
-- dwell) and are the real exploit surface, so the client explicitly claims them
-- here. The payload is deliberately scoped to only these two states -- Zap's own
-- type validation (write_checks above) then rejects any other claim before it
-- reaches handler logic at all. The server never trusts a client-sent timestamp
-- for the dwell check -- it validates against its own entry-timestamp for when it
-- observed the player enter Run, same lag-compensation principle as parry
-- (docs/ARCHITECTURE.md §4).
--
-- NOTE: Zap has no native per-event rate-limit field (verified against
-- zap.redblox.dev/config/events and /config/options.html, 2026-09-13), despite
-- docs/ARCHITECTURE.md §10 describing rate limits as declared here. Enforced
-- instead via Shared/Util/RateLimiter.luau, wired into MovementValidationService
-- when that lands in Step 2 -- see docs/MOVEMENT.md §5.
-- "CrouchDown"/"CrouchUp" (docs/MOVEMENT.md §10, Crouch/Slide slice) are
-- DIFFERENT in kind from "Run"/"Sprint" -- they don't name an FSM target
-- state being claimed, they name the Ctrl key's own press/release EDGE. This
-- is deliberate: unlike Run/Sprint (whose claim IS the earned target state),
-- a single Ctrl key resolves into up to four different states (CrouchIdle,
-- CrouchWalk, Slide, or a crouched landing) depending on context the SERVER
-- already re-derives every Heartbeat for Idle/Walk/Run/Sprint today --
-- encoding a specific target name per edge would just duplicate that
-- decision. The server only ever uses these two to set/clear one session
-- flag (`PlayerSession.crouchHeld`); every resulting FSM transition is
-- mirrored passively from it, the same way Idle<->Walk already is.
type ClaimableMovementState = enum { "Run", "Sprint", "CrouchDown", "CrouchUp" }

event RequestMovementTransition = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: ClaimableMovementState,
}

-- Qinggong traversal claims (TRAVERSAL-ROADMAP.md §6) -- DIFFERENT in kind
-- from RequestMovementTransition above: these are the five new expansion
-- moves, each validated server-side via its own resimulation
-- (MovementValidationService) rather than the passive-mirror/dwell-timestamp
-- model Run/Sprint use, since they involve real physics impulses a modified
-- client could otherwise fake outright. Only "DoubleJump" exists yet (Phase
-- 1) -- Dash/WallRun/WallClimb/Vault are added to this enum as their own
-- phases land, never all five speculatively up front.
type ClaimableTraversalMove = enum { "DoubleJump" }

event ClaimTraversalMove = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: ClaimableTraversalMove,
}

-- Debug overlay (F4, developer-only) ------------------------------------------
--
-- One-way server -> owning-client broadcast of MovementValidationService's
-- mirrored FSM state, so the overlay can flag client/server disagreement instead
-- of only ever showing the client's own (self-reported, untrustworthy) view. Only
-- ever fired to the one player it describes (`Fire(player, data)`), never
-- FireAll -- see docs/MOVEMENT.md.
type DebugMovementState = enum {
	"Idle",
	"Walk",
	"Run",
	"Sprint",
	"Airborne",
	"CrouchIdle",
	"CrouchWalk",
	"Slide",
	"SlideJump",
	"DoubleJump",
}

-- One recent speed-sanity correction (Shared/Util/ViolationTracker.luau's
-- per-key history, docs/MOVEMENT.md §8) -- the same flatDelta/maxDistance/
-- elapsed numbers SPEED_SANITY_DEBUG_LOGGING already prints server-side,
-- captured into a record instead of only ever printed. `ageSeconds` is
-- computed fresh server-side on every broadcast (`os.clock() - recordedAt`)
-- rather than sending the raw `os.clock()` timestamp, since the two machines'
-- clocks aren't comparable.
type MovementViolationEntry = struct {
	flatDelta: f32,
	maxDistance: f32,
	elapsed: f32,
	ageSeconds: f32,
}

event MovementDebugState = {
	from: Server,
	type: Unreliable,
	call: SingleSync,
	data: struct {
		state: DebugMovementState,
		runDuration: f32?,
		violationCount: u16,
		violations: MovementViolationEntry[0..5],
	},
}

-- Developer-only teleport tool. Every player-initiated remote still goes through
-- Zap like any other (docs/ARCHITECTURE.md §10) even though only a developer is
-- ever meant to reach it -- the authorization check lives entirely server-side
-- (RunService:IsStudio() or a hardcoded UserId allowlist, checked first, before
-- anything else in the handler runs) since client-side UI visibility is not a
-- security boundary.
event RequestDevTeleport = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: vector,
}

-- Live movement tuning (F4 overlay "Tuning" tab, developer-only) -------------
--
-- Lets a developer override a subset of MovementConstants for their OWN
-- session only, with no republish -- see Shared/Movement/MovementTuning.luau
-- and Server/State/MovementTuningState.luau. `value: nil` clears the override,
-- reverting that one name back to the shipped MovementConstants value.
type TunableConstantName = enum {
	"RunDoubleTapWindowSeconds",
	"SprintThresholdSeconds",
	"WalkSpeed",
	"RunSpeed",
	"SprintSpeed",
	"JumpPower",
	"SprintForwardDeadzone",
	"SpeedToleranceMultiplier",
	"CrouchSpeed",
	"SlideDecayRate",
	"SlideJumpBoostAmount",
	"HardLandingFallSpeedThreshold",
	"LandingAnimationHoldSeconds",
	"DoubleJumpForce",
	"DoubleJumpDecayDurationSeconds",
}

event RequestSetTuning = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: struct {
		name: TunableConstantName,
		value: f32?,
	},
}

-- One-way broadcast of this session's EFFECTIVE constants (override merged
-- over MovementConstants, or the raw constants if nothing is overridden) so
-- client and server read back the exact same numbers -- a divergence here is
-- exactly the class of bug the 2026-09-13 rubber-banding investigation
-- (docs/MOVEMENT.md §5) had to fix once already. Struct field names are
-- lowerCamel per this file's own convention (see MovementDebugState above);
-- Server/Services/MovementTuningService.luau and
-- Client/Controllers/Movement/TuningSnapshot.luau each do the one small
-- name-case mapping to/from Shared/Movement/MovementTuning's PascalCase keys.
event TuningState = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: struct {
		runDoubleTapWindowSeconds: f32,
		sprintThresholdSeconds: f32,
		walkSpeed: f32,
		runSpeed: f32,
		sprintSpeed: f32,
		jumpPower: f32,
		sprintForwardDeadzone: f32,
		speedToleranceMultiplier: f32,
		crouchSpeed: f32,
		slideDecayRate: f32,
		slideJumpBoostAmount: f32,
		hardLandingFallSpeedThreshold: f32,
		landingAnimationHoldSeconds: f32,
		doubleJumpForce: f32,
		doubleJumpDecayDurationSeconds: f32,
	},
}

-- Noclip/fly scouting tool (F4 overlay, developer-only) ----------------------
--
-- Per-session toggle, server-authorized like every other dev tool here.
-- Collision is disabled server-side (CanCollide replicates natively); the
-- actual fly movement is driven client-side by
-- Client/Controllers/Movement/NoclipController.luau, since the player's own
-- character is already network-owned by that client for ordinary movement.
-- MovementValidationService.enforceSpeedSanity exempts an active session via
-- Server/State/NoclipState.luau rather than trusting a client-reported flag.
event RequestSetNoclip = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: boolean,
}

event NoclipState = {
	from: Server,
	type: Reliable,
	call: SingleSync,
	data: boolean,
}

-- F4 overlay open/close signal (developer-only) ------------------------------
--
-- `MovementDebugState` above broadcasts every server Heartbeat -- without this,
-- that broadcast runs unconditionally for every developer session regardless
-- of whether their panel is even open, which is exactly the "no blanket
-- per-Heartbeat cost" mistake docs/MOVEMENT.md's own optimization standards
-- warn against elsewhere. `DebugOverlayController.setOpen` is the single
-- choke point every open/close path (F4, corner tab, close button) already
-- routes through, so this fires from there. Dev-gated server-side like every
-- other dev-only remote (DevToolsService.RegisterDevOnly) even though a
-- non-developer's client never sends it at all (DebugOverlayController.Init
-- returns early for them).
event RequestSetDebugOverlayOpen = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: boolean,
}
