--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

local function hasMoveInput(context: MovementContext): boolean
	return context.moveIntent.direction.Magnitude > 0
end

-- Topology: which states can graph-wise reach which. Purely "is this edge legal",
-- not "is it legal right now" -- that's CanEnter below. Shared client/server so both
-- FSM mirrors are built from the identical graph.
--
-- Crouch/Slide additions (docs/MOVEMENT.md §9): CrouchIdle is reachable
-- directly from BOTH Idle and Walk (and from Airborne, on landing), but
-- CrouchWalk is gated behind CrouchIdle -- pressing Ctrl always lands you in
-- CrouchIdle first, and CrouchWalk is only earned from there (or from
-- Airborne, on landing) once move input is present. Run/Sprint each only
-- reach Slide (never Crouch directly) -- Slide is what's earned by pressing
-- Ctrl while running, per the design; the crouch states themselves are only
-- ever reached from Slide once its decay crosses the threshold.
-- `Airborne -> Run`/`Airborne -> Sprint` (landing-resume fix): landing CAN now
-- target Run or Sprint directly -- `AirborneState.ResolveLandingTarget`
-- resumes whichever of those two this life was in the instant it left the
-- ground, provided forward is still held on touchdown -- so both need to be
-- real, reachable edges here, not just unused topology the way `-> Run` used
-- to be before this pass.
local Transitions: { [MovementState]: { MovementState } } = {
	[MovementStates.Idle] = {
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Airborne,
		MovementStates.CrouchIdle,
	},
	[MovementStates.Walk] = {
		MovementStates.Idle,
		MovementStates.Run,
		MovementStates.Airborne,
		MovementStates.CrouchIdle,
	},
	[MovementStates.Run] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Sprint,
		MovementStates.Airborne,
		MovementStates.Slide,
	},
	[MovementStates.Sprint] = {
		MovementStates.Idle,
		MovementStates.Run,
		MovementStates.Airborne,
		MovementStates.Slide,
	},
	[MovementStates.Airborne] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.DoubleJump,
		MovementStates.HardLanding,
	},
	[MovementStates.CrouchIdle] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.CrouchWalk,
		MovementStates.Airborne,
	},
	[MovementStates.CrouchWalk] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.CrouchIdle,
		MovementStates.Airborne,
	},
	[MovementStates.Slide] = {
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.SlideJump,
		MovementStates.Airborne,
	},
	[MovementStates.SlideJump] = { MovementStates.Airborne },

	-- DoubleJump hands back to Airborne once its impulse ends -- the character
	-- is still airborne, just with new vertical velocity, same as SlideJump's
	-- own single edge back out. The grounded targets alongside it cover the
	-- rarer "landed mid-impulse" case (TRAVERSAL-ROADMAP.md §4): Airborne's
	-- own CanEnter requires `not grounded`, which has already failed by the
	-- time that case is detected, so DoubleJumpState resolves the landing
	-- target directly (AirborneState.ResolveLandingTarget) instead of
	-- bouncing through an Airborne hop that would be rejected.
	[MovementStates.DoubleJump] = {
		MovementStates.Airborne,
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.HardLanding,
	},

	-- HardLanding (docs/MOVEMENT.md §10 rework): a real, timed lock state
	-- entered instead of the normal landing target when the fall was big
	-- enough (see `AirborneState.ResolveLandingTarget`'s `fallHeight` check).
	-- Resolves back out to whichever grounded state the held input actually
	-- calls for once its own lock duration elapses (`HardLandingState.Update`,
	-- and the server's matching `mirrorPassiveTransitions` branch, both just
	-- re-run `ResolveLandingTarget` at that point) -- so every ordinary
	-- grounded target is a legal edge out of it. `Airborne` is included too,
	-- same defensive "ground can vanish out from under a locked player" edge
	-- CrouchIdle/CrouchWalk already carry.
	[MovementStates.HardLanding] = {
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.Airborne,
	},
}

-- CanEnter: is this transition legal RIGHT NOW, given live context. Shared
-- client/server per docs/MOVEMENT.md §1 so a hacked client can't diverge from what
-- the server will accept.
--
-- Crouch/Slide additions (docs/MOVEMENT.md §9): none of these re-check
-- "coming from the right state" (e.g. Slide re-checking "currently Run or
-- Sprint") -- that's topology's job above, same principle Sprint's own
-- CanEnter already relies on (it never re-checks "currently Run" either).
-- CrouchIdle/CrouchWalk/Slide DO check `crouchHeld` here, unlike Sprint's
-- dwell timer -- there's no "who calls RequestTransition" gate protecting
-- these the way InputController's double-tap detector is the SOLE caller for
-- Run, so the legality has to be self-contained in CanEnter.
local CanEnter: { [MovementState]: (context: MovementContext) -> boolean } = {
	[MovementStates.Idle] = function(context: MovementContext): boolean
		return context.grounded
	end,

	[MovementStates.Walk] = function(context: MovementContext): boolean
		return context.grounded and hasMoveInput(context)
	end,

	[MovementStates.Run] = function(context: MovementContext): boolean
		return context.grounded and hasMoveInput(context)
	end,

	[MovementStates.Sprint] = function(context: MovementContext): boolean
		if not context.grounded then
			return false
		end
		-- Landing-resume fix: a landing that resolves straight back to Sprint
		-- (`AirborneState.ResolveLandingTarget`) has no `runDuration` to check --
		-- `fsm.current` is still Airborne, not Run, at the instant this runs.
		-- `preAirborneLocomotion` already encodes that this life was legitimately
		-- IN Sprint (past its own dwell check) the instant it left the ground, so
		-- re-checking the dwell timer here would only ever reject a resume that
		-- has already earned it once -- this is a carry-through, not a fresh
		-- grant, same distinction the landing-momentum speed grace already draws
		-- for a decreasing cap.
		if context.preAirborneLocomotion == MovementStates.Sprint then
			return true
		end
		local threshold = context.constants.SprintThresholdSeconds
		return context.runDuration ~= nil and (context.runDuration :: number) >= threshold
	end,

	[MovementStates.Airborne] = function(context: MovementContext): boolean
		return not context.grounded
	end,

	[MovementStates.CrouchIdle] = function(context: MovementContext): boolean
		return context.grounded and context.crouchHeld
	end,

	[MovementStates.CrouchWalk] = function(context: MovementContext): boolean
		return context.grounded and context.crouchHeld and hasMoveInput(context)
	end,

	-- No dwell condition, unlike Sprint -- immediate the instant Ctrl is held
	-- while grounded (docs/MOVEMENT.md §9). "Currently Run or Sprint" needs no
	-- explicit check: Slide is only topologically reachable from those two.
	[MovementStates.Slide] = function(context: MovementContext): boolean
		return context.grounded and context.crouchHeld
	end,

	-- Mirrors Airborne's own predicate exactly, not a coincidence: by the time
	-- `context.jumping` reads true, `context.grounded` has already flipped
	-- false too (both read off the same single `Humanoid:GetState()`, which can
	-- only ever be ONE state at a time) -- so SlideJump's real gate is "jump
	-- was pressed," expressed as "who calls RequestTransition" (SlideState's
	-- own Update, only when `context.jumping`), same as Sprint's dwell-timer
	-- gate is expressed as "who calls" rather than encoded here. Topology
	-- alone enforces "currently in Slide."
	[MovementStates.SlideJump] = function(context: MovementContext): boolean
		return not context.grounded
	end,

	-- Reachable only from Airborne (topology above), needs the one midair jump
	-- not yet spent this life (TRAVERSAL-ROADMAP.md §4) -- `doubleJumpUsed` is
	-- reset the instant the character actually lands (see
	-- Client/Controllers/Movement/init.luau and
	-- Server/Services/MovementValidationService.luau, both of which reset it
	-- on the same "entered a grounded state" edge), mirroring the reference
	-- controller's "resets once grounded" behavior without its raw 5-second
	-- timer, which was only there to compensate for that codebase having no
	-- clean per-life reset hook.
	[MovementStates.DoubleJump] = function(context: MovementContext): boolean
		return not context.grounded and not context.doubleJumpUsed
	end,

	-- Same shape as Idle's own predicate (docs/MOVEMENT.md §10 rework) --
	-- "was this landing big enough" is `ResolveLandingTarget`'s decision, not
	-- CanEnter's; this only ever needs to confirm the landing is real.
	[MovementStates.HardLanding] = function(context: MovementContext): boolean
		return context.grounded
	end,
}

local StateRules = {
	Transitions = Transitions,
	CanEnter = CanEnter,
	HasMoveInput = hasMoveInput,
}

return StateRules
