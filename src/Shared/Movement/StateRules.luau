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
-- Crouch/Slide additions (docs/MOVEMENT.md §9): CrouchIdle/CrouchWalk are
-- reachable directly from BOTH Idle and Walk (and from Airborne, on landing),
-- not funneled through each other first -- a player holding Ctrl+W from a
-- dead stop should land in CrouchWalk the same tick, not CrouchIdle-then-
-- CrouchWalk a frame later. Run/Sprint each only reach Slide (never Crouch
-- directly) -- Slide is what's earned by pressing Ctrl while running, per the
-- design; the crouch states themselves are only ever reached from Slide once
-- its decay crosses the threshold. `Airborne -> Run` was already unused
-- topology (landing never attempts Run, see docs/MOVEMENT.md §2) and is left
-- as-is, untouched by this pass.
local Transitions: { [MovementState]: { MovementState } } = {
	[MovementStates.Idle] = {
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Airborne,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
	},
	[MovementStates.Walk] = {
		MovementStates.Idle,
		MovementStates.Run,
		MovementStates.Airborne,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
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
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
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
		local threshold = context.constants.SprintThresholdSeconds
		return context.grounded and context.runDuration ~= nil and (context.runDuration :: number) >= threshold
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
}

local StateRules = {
	Transitions = Transitions,
	CanEnter = CanEnter,
	HasMoveInput = hasMoveInput,
}

return StateRules
