--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)

-- `forward`/`backward`/`strafeLeft`/`strafeRight` are the raw WASD axis holds, kept
-- alongside the resolved `direction` because Sprint's continuation rule cares about
-- the raw forward key specifically (tolerates forward-diagonal, drops on backpedal
-- or pure strafe) -- see docs/MovementSystem.md §3. `direction` is the camera-relative,
-- world-space vector actually driving movement.
export type MoveIntent = {
	direction: Vector3,
	forward: boolean,
	backward: boolean,
	strafeLeft: boolean,
	strafeRight: boolean,
}

-- `constants` is this session's EFFECTIVE movement tuning (live per-session
-- overrides merged over MovementConstants, or MovementConstants unmodified --
-- see Shared/Movement/MovementTuning.luau, docs/MovementSystem.md §10). Added here,
-- not read directly off MovementConstants, so Shared/Movement/StateRules.luau's
-- CanEnter predicates (e.g. Sprint's dwell check) stay pure functions of
-- `context` alone -- both client and server build `constants` from the exact
-- same source (their own session's tuning state) before calling into
-- StateRules, so this can never itself become a client/server divergence.
-- `jumping` (docs/MovementSystem.md §4.2, Crouch/Slide slice) is the Humanoid's own
-- `Jumping` state, read the same way `grounded` already is -- both sides
-- derive it from the same already-replicated `Humanoid:GetState()`, so it's a
-- shared context field rather than something only one side computes.
-- SlideJump's entry gate reads this (jump pressed while sliding), never a
-- claim -- exactly like Airborne's own entry, no discrete gesture to earn.
--
-- `crouchHeld` is the one signal in this whole system that ISN'T derivable
-- from anything Roblox already replicates (unlike `moveIntent`/`grounded`/
-- `jumping`, all read off `Humanoid`) -- the server only has it because the
-- client explicitly tells it (`RequestMovementTransition`'s "CrouchDown"/
-- "CrouchUp" claims, docs/MovementSystem.md §4.2), stored per-session
-- (`PlayerSession.crouchHeld`) rather than derived fresh each frame the way
-- everything else in this type is.
-- `doubleJumpUsed` (docs/MovementSystem.md §5, Phase 1) is the one other signal
-- in this type that isn't derivable fresh from Humanoid replication each
-- frame -- like `crouchHeld`, it has to be tracked as per-life state by
-- whoever owns the FSM lifecycle (`Movement/init.luau` client-side,
-- `PlayerSession` server-side), reset the instant the character lands and
-- set once DoubleJump is entered, never recomputed from a physics read.
-- `preAirborneLocomotion` (landing-resume fix) is Run/Sprint if that's the
-- tier this life was in the instant it left the ground, nil otherwise --
-- same per-life tracked-not-derived treatment as `doubleJumpUsed`: set on the
-- Run/Sprint -> Airborne edge, carried through an Airborne<->DoubleJump hop,
-- cleared the instant a landing actually resolves. `AirborneState.
-- ResolveLandingTarget` (and its server mirror) reads this to land straight
-- back into the SAME tier when forward is still held, instead of always
-- demoting to Walk -- and `StateRules.CanEnter[Sprint]` reads it too, since a
-- resumed Sprint has already legitimately passed the dwell check once and
-- shouldn't have to re-clear it after every single jump.
-- `fallHeight` (HardLanding rework) is the real height, in studs, of the
-- excursion about to end -- the peak Y reached since this life last left the
-- ground, minus the current Y -- or nil while no excursion is in progress
-- (grounded, or the very first frame of one before a peak has been sampled).
-- Tracked the same per-life, not-derived-from-`context`-alone way as
-- `doubleJumpUsed`/`preAirborneLocomotion` (`Movement/init.luau`'s own
-- `peakHeight`, `PlayerSession.peakHeight` server-side), off each side's own
-- trusted `rootPart.Position.Y` -- the server NEVER derives this from
-- anything the client asserts (docs/ARCHITECTURE.md §3). `AirborneState.
-- ResolveLandingTarget` (and its server mirror) reads this against
-- `constants.HardLandingHeightThreshold` to decide whether a landing forces
-- the `HardLanding` lock instead of resolving normally.
-- `horizontalVelocity` (docs/MovementSystem.md §4.5) is the real
-- flattened AssemblyLinearVelocity, read fresh by each side from its own
-- trusted source (client: CharacterMover:GetHorizontalVelocity, server: its
-- own rootPart read) -- never derived from moveIntent, which is INPUT, not
-- actual physical velocity. CanEnter[WallRun]'s speed gate and
-- TraversalMath.WallRunTangent's momentum-agreement sign both need the real
-- vector, not the intent.
-- `wallRunQuery` (docs/MovementSystem.md §4.5) is this frame's
-- throttled side-cast result -- populated by each side from its own probe
-- (SpatialQueries.QueryWallRun) BEFORE calling into StateRules, same
-- "computed by the caller, never inside StateRules itself" treatment every
-- other spatial-claim field in this codebase already gets. nil whenever no
-- wall is currently in range on either side, or while not airborne (both
-- sides only probe at all while `not grounded`).
-- `wallClingQuery` (docs/MovementSystem.md §4.6/§5) is this frame's cling-wall
-- probe -- same "computed by the caller, never inside StateRules itself"
-- treatment as `wallRunQuery` right above: each side populates it from its
-- own `SpatialQueries.castClingWall` call BEFORE building context, so
-- `CanEnter[WallCling]` stays a pure read. nil whenever no clingable wall is
-- in range. Only the STRUCTURAL gates (Anchored/CanCollide, verticality) are
-- folded into `castClingWall` itself -- the facing-angle gate is deliberately
-- NOT baked in here (unlike an earlier version of this field), so it can be
-- checked in `CanEnter[WallCling]` against `constants.WallClingMaxFacingAngleDegrees`
-- instead, the same "cast finds the wall, CanEnter judges legality against a
-- LIVE tunable" split `wallRunQuery`/`CanEnter[WallRun]` already established.
-- `facingDirection` (below) is what that check reads.
-- `facingDirection` (docs/MovementSystem.md §4.6) is each side's own real
-- current facing (client: `CharacterMover:GetFacingDirection()`, server: its
-- own `rootPart.CFrame.LookVector`) -- optional so existing `buildContext`
-- call sites don't need updating until the server-side probe lands; nil is
-- treated as "can't verify facing," which fails the check closed rather than
-- open.
-- `wallClingLockoutUntil` is this life's/session's own server-owned re-grab
-- deadline (docs/MovementSystem.md §4.6) -- optional so existing
-- `buildContext` call sites don't need updating until the state that reads it
-- actually lands; nil is treated as "no lockout in effect."
-- `lastWallLeapWall` (docs/MovementSystem.md §4.6/§5) is the physical
-- `BasePart` this life/session most recently wall-leapt from, cleared on
-- landing or on touching a different wall -- there is no pre-existing
-- "wall leap memory" field to reuse (`WallRunQueryResult` never tracked the
-- hit instance before this), so this is a new field, not a repurposed one.
-- `wallClingBoostUsed` (docs/MovementSystem.md §4.6/§5) is whether the
-- current cling has already spent its one free boost -- per-cling, not
-- per-life, set false on every WallCling entry and true the instant WallBoost
-- is entered, same tracked-not-derived treatment as `doubleJumpUsed`.
-- Optional (unlike `doubleJumpUsed`) since it only matters once WallCling
-- actually exists as a reachable state -- nil reads as "not used," matching
-- `CanEnter[WallBoost]`'s own `not context.wallClingBoostUsed` check.
-- `wallClingElapsed` is how long the current cling has lasted, from each
-- side's own cling entry (nil when not clinging); `CanEnter[WallBoost]`
-- requires `WallBoostMinClingSeconds` of it (docs/MovementSystem.md §4.6).
-- `qinggong` (§0/§3) is the resource gate Vault (and any future Qinggong
-- move) reads --
-- still an open design decision (is this the same Qi pool combat will spend,
-- or a separate movement-only pool?) per the roadmap's own risk register, so
-- both sides default it to "always available" (`math.huge`) until that
-- resource system exists, same "wired as an abstracted field now, pointed at
-- a real source later without a rewrite" treatment the roadmap calls for.
-- `cameraLocked` (landing-resume fix, hardened 2026-09-18) is `Humanoid.
-- AutoRotate == false` -- a plain replicated property both sides already
-- trust elsewhere (`Mirror.PassiveTransitions`'s own Sprint-demotion branch
-- reads it directly for the identical reason this field exists). Needed
-- because `moveIntent.forward` means two different things depending on this:
-- while LOCKED (Shift Lock/first-person), `FacingController` snaps facing to
-- the camera every frame, so `classifyMoveIntent`'s facing-vs-MoveDirection
-- dot product is a real, reliable "are you actually holding forward" signal.
-- While UNLOCKED, `Humanoid.AutoRotate` instead turns facing toward
-- MoveDirection GRADUALLY (Roblox's own ground/air controller), so facing
-- can lag MoveDirection by several frames after any turn or takeoff --
-- exactly the "facing hasn't caught up yet" window a landing tends to land
-- in. `LandingResolution.Resolve` uses this to skip the unreliable geometric
-- check while unlocked (any held input already counts as forward there, per
-- this codebase's own established "unlocked -> always facing where you
-- walk" convention -- see LocomotionAnimator's Walk-bucketing comment).
export type MovementContext = {
	moveIntent: MoveIntent,
	grounded: boolean,
	jumping: boolean,
	crouchHeld: boolean,
	doubleJumpUsed: boolean,
	runDuration: number?,
	preAirborneLocomotion: MovementStates.MovementState?,
	fallHeight: number?,
	horizontalVelocity: Vector3,
	wallRunQuery: SpatialQueries.WallRunQueryResult?,
	wallClingQuery: SpatialQueries.ClingWallHit?,
	facingDirection: Vector3?,
	wallClingLockoutUntil: number?,
	wallClingBoostUsed: boolean?,
	wallClingElapsed: number?,
	lastWallLeapWall: BasePart?,
	qinggong: number,
	cameraLocked: boolean,
	constants: MovementTuning.EffectiveMovementConstants,
}

return {}
