--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StateMachine = require(ReplicatedStorage.Shared.FSM.StateMachine)
local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

local CharacterMover = require(script.Parent.CharacterMover)
local FacingController = require(script.Parent.Parent.Presentation.FacingController)

type MovementState = MovementStates.MovementState

-- Client-only superset of the Shared MovementContext (Shared/Types/MovementTypes):
-- adds the two things only client-side state Enter/Update/Exit bodies need
-- (CanEnter predicates, shared with the server, only ever see the plain
-- MovementContext). Lives in its own leaf module so init.luau and the State
-- modules can both depend on it without requiring each other.
-- `slideSpeed` (docs/MovementSystem.md §4.2) is Slide's own currently-decaying speed,
-- exposed the same way Run's dwell duration already is (`RunState.GetDuration()`
-- -> `context.runDuration`): a state exports its own internal timer/value via a
-- module function, `Movement/init.luau`'s `buildContext` reads it in, and any
-- OTHER state that needs it (SlideJumpState, for its boost) reads it off
-- `context` rather than requiring the sibling state module directly. Client-only
-- (not part of the shared MovementContext) -- the server never simulates
-- Slide's exact decay curve, it uses a flat SprintSpeed (+ slope
-- amplification) ceiling instead (see `maxSpeedForState`), so it has no
-- equivalent use for this value.
-- `slideDirection` (docs/MovementSystem.md §4) is the companion vector,
-- exposed the exact same way (`SlideState.GetCurrentDirection` ->
-- `context.slideDirection`) -- needed once Slide itself drives a real
-- `LinearVelocity` instead of a bare WalkSpeed magnitude, so "the speed Slide
-- had a moment ago" (SlideJumpState's boost) has a real direction to apply it
-- along.
-- `wallRunEntry{Normal,Tangent}` (docs/MovementSystem.md §4.5) are
-- WallRunState's own locked entry snapshot, exposed the identical way
-- (`WallRunState.GetEntryNormal`/`GetEntryTangent` -> these fields) so
-- WallLeapState can read "what was I doing when I entered the run" without
-- requiring WallRunState directly. Client-only -- the server's own claim
-- validation (still pending, §6) resimulates the launch from its OWN stored
-- entry values, never anything the client reports here. No
-- `wallRunEntrySpeed` (removed 2026-09-18, WallLeap redesign) -- the leap
-- reads REAL current velocity off `characterMover` instead, since the run's
-- speed never actually decays/changes mid-hold.
-- `facingController` (docs/MovementSystem.md §4.5, playtest fix 2026-09-18) lets WallRunState
-- lock the rootPart's facing to its own entry tangent for the hold's duration
-- -- otherwise FacingController's own per-frame camera/AutoRotate logic keeps
-- spinning the character mid-run (spinning the camera in Shift Lock, or plain
-- WASD when unlocked), which both looks wrong and can knock the run off its
-- locked tangent early.
-- `wallRunEntryInstance` (docs/MovementSystem.md §4.6/§5) is WallRunState's
-- own locked entry wall part, exposed the same GetEntry*-> field way as
-- `wallRunEntryNormal`/`wallRunEntryTangent` -- read by Movement/init.luau's
-- own `fsm.changed` bookkeeping (not any state) to snapshot `lastWallLeapWall`
-- at the exact WallRun -> WallLeap edge, BEFORE WallRunState.Exit nils its own
-- copy. Client-only, same reasoning as the other wallRunEntry* fields -- the
-- server tracks its OWN wall-leap-wall bookkeeping independently.
-- `wallClingNormal` (docs/MovementSystem.md §4.6) is WallClingState's own
-- locked cling normal, exposed the same GetNormal-> field way -- read by
-- WallBoostState.Enter to compute the launch impulse, captured into context
-- BEFORE WallClingState.Exit nils its own copy, same pre-Exit-snapshot
-- pattern `wallRunEntryInstance` already established for the WallLeap edge.
-- `cameraLook` (docs/MovementSystem.md §4.8) is the camera's look vector,
-- which steers Vault's launch. Client-only: the server has no camera, so it
-- bounds the launch's magnitude and never its direction.
export type ClientMovementContext = MovementTypes.MovementContext & {
	characterMover: CharacterMover.CharacterMover,
	facingController: FacingController.FacingController,
	fsm: StateMachine.StateMachine<MovementState, MovementTypes.MovementContext>,
	slideSpeed: number?,
	slideDirection: Vector3?,
	wallRunEntryNormal: Vector3?,
	wallRunEntryTangent: Vector3?,
	wallRunEntryInstance: BasePart?,
	wallClingNormal: Vector3?,
	cameraLook: Vector3?,
}

return {}
