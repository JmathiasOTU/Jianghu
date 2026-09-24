--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementTypes = require(ReplicatedStorage.Shared.Types.MovementTypes)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local SpatialQueries = require(ReplicatedStorage.Shared.Movement.SpatialQueries)
local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)

type MovementState = MovementStates.MovementState
type MovementContext = MovementTypes.MovementContext

local function hasMoveInput(context: MovementContext): boolean
	return context.moveIntent.direction.Magnitude > 0
end

-- Topology: which states can graph-wise reach which. Purely "is this edge legal",
-- not "is it legal right now" -- that's CanEnter below. Shared client/server so both
-- FSM mirrors are built from the identical graph.
--
-- Crouch/Slide additions (docs/MovementSystem.md §4.2): CrouchIdle is reachable
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
		MovementStates.WallRun,
		MovementStates.WallCling,
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
	-- rarer "landed mid-impulse" case (docs/MovementSystem.md §5): Airborne's
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

	-- HardLanding (docs/MovementSystem.md §4.4 rework): a real, timed lock state
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

	-- WallRun (docs/MovementSystem.md §5): the grounded targets
	-- alongside Airborne cover the mid-run-landing case, same reason
	-- DoubleJump's own table carries grounded targets alongside its primary
	-- exit. CrouchIdle/CrouchWalk are included even though the original wall-run
	-- design omitted them -- LandingResolution.Resolve can land a crouched
	-- player into either one, and leaving them out would strand the FSM in
	-- WallRun the instant that resolution ran (the exact "Sprint dead end"
	-- shape docs/MovementSystem.md §3 already had to fix once). HardLanding for the
	-- same reason (audit M-005): a wall run entered partway down a >= threshold
	-- fall resolves its landing to HardLanding.
	[MovementStates.WallRun] = {
		MovementStates.Airborne,
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.HardLanding,
		MovementStates.WallLeap,
	},

	-- WallLeap (docs/MovementSystem.md §4.5): single edge back to Airborne, taken
	-- synchronously in the same frame WallRun -> WallLeap is -- same
	-- one-tick-lifetime shape SlideJump's own table already established. No
	-- CanEnter[WallLeap] predicate exists (topology alone gates it, per
	-- StateMachine.RequestTransition's own "rules[next], if present" contract)
	-- since legality here is just "you have to actually be wall-running,"
	-- already the entire reachability question this edge answers.
	[MovementStates.WallLeap] = {
		MovementStates.Airborne,
	},

	-- WallCling (docs/MovementSystem.md §4.6): reachable only from Airborne
	-- (see the Airborne table above), can hand off to WallBoost or drop/time
	-- out/lose-the-wall straight back to Airborne. Never a direct edge back
	-- into WallCling from WallBoost -- a re-cling always requires a fresh
	-- Space press through Airborne (CanEnter[WallCling]'s own lockout check),
	-- same "topology says WHERE, CanEnter says WHEN" split every other state
	-- here already follows. The grounded targets alongside Airborne/WallBoost
	-- cover the mid-cling-landing case -- same reason WallRun's own table
	-- carries them (`mirrorPassiveTransitions`'s landing branch calls
	-- `LandingResolution.Resolve`, which returns a GROUNDED state directly,
	-- never `Airborne` -- omitting these left the server's mirror unable to
	-- ever leave WallCling on a real landing, found 2026-09-19: the mirror
	-- stayed stuck in WallCling indefinitely once grounded, since `context.
	-- grounded` short-circuits the duration/wall-lost fallback every
	-- Heartbeat and the landing transition itself kept silently failing).
	[MovementStates.WallCling] = {
		MovementStates.Airborne,
		MovementStates.WallBoost,
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.HardLanding,
	},

	-- WallBoost (docs/MovementSystem.md §4.6): usually a single edge back to
	-- Airborne after its own short `WallBoostStateDuration` window -- reachable
	-- only from WallCling (see the WallCling table above). Same grounded-target
	-- set as WallCling just above, for the identical mid-boost-landing reason
	-- (a boost launched near the ground, or one that immediately clears a low
	-- ledge, can land before its own duration window even elapses).
	[MovementStates.WallBoost] = {
		MovementStates.Airborne,
		MovementStates.Idle,
		MovementStates.Walk,
		MovementStates.Run,
		MovementStates.Sprint,
		MovementStates.CrouchIdle,
		MovementStates.CrouchWalk,
		MovementStates.HardLanding,
	},
}

-- CanEnter: is this transition legal RIGHT NOW, given live context. Shared
-- client/server per docs/MovementSystem.md §2 so a hacked client can't diverge from what
-- the server will accept.
--
-- Crouch/Slide additions (docs/MovementSystem.md §4.2): none of these re-check
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
	-- while grounded (docs/MovementSystem.md §4.2). "Currently Run or Sprint" needs no
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
	-- not yet spent this life (docs/MovementSystem.md §5) -- `doubleJumpUsed` is
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

	-- Same shape as Idle's own predicate (docs/MovementSystem.md §4.4 rework) --
	-- "was this landing big enough" is `ResolveLandingTarget`'s decision, not
	-- CanEnter's; this only ever needs to confirm the landing is real.
	[MovementStates.HardLanding] = function(context: MovementContext): boolean
		return context.grounded
	end,

	-- Five gates, all required together (docs/MovementSystem.md §4.5): airborne, a real wall this
	-- frame, real momentum (no standstill wall run), moving ALONG the wall's tangent rather
	-- than into/away from it, and facing along it too. `wallRunQuery`/`horizontalVelocity` are both populated by the caller
	-- BEFORE this runs (see their own MovementTypes.luau doc comments) -- never derived in here,
	-- same "CanEnter stays a pure read of context" principle every other predicate above already
	-- follows.
	[MovementStates.WallRun] = function(context: MovementContext): boolean
		if context.grounded then
			return false
		end
		local wallQuery = context.wallRunQuery
		if not wallQuery then
			return false
		end
		-- No WallLeap chains on one wall (audit M-037, designer answer
		-- 2026-09-24): the wall just leapt from stays off-limits until the
		-- character lands, same memory WallCling already uses.
		if context.lastWallLeapWall and wallQuery.instance == context.lastWallLeapWall then
			return false
		end
		if context.horizontalVelocity.Magnitude < context.constants.WallRunMinEntrySpeed then
			return false
		end
		if context.moveIntent.direction.Magnitude == 0 then
			return false
		end
		local tangent = TraversalMath.WallRunTangent(wallQuery.normal, context.horizontalVelocity)
		local threshold = context.constants.WallRunEntryDotThreshold
		if context.moveIntent.direction.Unit:Dot(tangent) < threshold then
			return false
		end
		-- Facing the way you run, not just moving that way (2026-09-24 playtest):
		-- in Shift Lock, backpedalling along a wall satisfied every gate above
		-- and wall-ran backwards.
		local facing = context.facingDirection
		if not facing then
			return false
		end
		local flatFacing = Vector3.new(facing.X, 0, facing.Z)
		if flatFacing.Magnitude < MovementConstants.DirectionEpsilon then
			return false
		end
		return flatFacing.Unit:Dot(tangent) >= threshold
	end,

	-- WallCling (docs/MovementSystem.md §5): airborne, off any active
	-- re-grab lockout, a real head-on wall this frame, and not the wall this
	-- life/session just leapt from. `wallClingQuery` is populated by the
	-- caller BEFORE this runs (SpatialQueries.castClingWall, same
	-- "computed by the caller" treatment `wallRunQuery` already gets) --
	-- that cast only enforces STRUCTURAL legality (Anchored/CanCollide,
	-- verticality); the facing-angle check happens HERE, against the live
	-- tunable `constants.WallClingMaxFacingAngleDegrees`, the same
	-- cast-finds-it/CanEnter-judges-it split `wallRunQuery`/`CanEnter[WallRun]`
	-- already established. No combat-FSM gate here (unlike the plan's own
	-- assumption 2) -- this codebase has no Stagger/PostureBreak/Defeated FSM
	-- state yet to check against.
	[MovementStates.WallCling] = function(context: MovementContext): boolean
		if context.grounded then
			return false
		end
		if
			context.wallClingLockoutUntil
			and os.clock() < (context.wallClingLockoutUntil :: number)
		then
			return false
		end
		local wallQuery = context.wallClingQuery
		if not wallQuery then
			return false
		end
		if context.lastWallLeapWall and wallQuery.instance == context.lastWallLeapWall then
			return false
		end
		if not context.facingDirection then
			return false
		end
		local facingAngle =
			SpatialQueries.facingAngleToWallDegrees(context.facingDirection, wallQuery.normal)
		return facingAngle <= context.constants.WallClingMaxFacingAngleDegrees
	end,

	-- WallBoost (docs/MovementSystem.md §5): reachable only from WallCling
	-- (topology above) and only once per cling -- "currently WallCling" needs
	-- no re-check here, same principle SlideJump's own CanEnter already
	-- relies on for its topology-gated "currently Slide."
	[MovementStates.WallBoost] = function(context: MovementContext): boolean
		if context.wallClingBoostUsed then
			return false
		end
		local elapsed = context.wallClingElapsed
		return elapsed ~= nil and elapsed >= context.constants.WallBoostMinClingSeconds
	end,
}

local StateRules = {
	Transitions = Transitions,
	CanEnter = CanEnter,
	HasMoveInput = hasMoveInput,
}

return StateRules
