--!strict

-- Pure functions, one per traversal move (TRAVERSAL-ROADMAP.md §3/§9) --
-- client prediction and server resimulation both call these directly rather
-- than each keeping their own copy of the formula, which is the whole point
-- of the "full trajectory resimulation" decision (§0/§7): resimulation only
-- agrees with the client if both sides run the literal same math, not two
-- hand-synced copies. No stored state of any kind here -- nothing in this
-- module needs a Trove or a cleanup path.

local TraversalMath = {}

-- DoubleJump vertical impulse (mechanic 2, §9): starts at `force`, decays
-- toward roughly half of itself by `decayDuration`, then holds at that floor
-- for any elapsed time beyond it (the state itself is responsible for exiting
-- back to Airborne once its own duration/landing condition is met -- this
-- function only ever describes "what should the impulse read right now",
-- never when to stop applying it).
function TraversalMath.DoubleJumpVerticalVelocity(elapsed: number, force: number, decayDuration: number): number
	local t = if decayDuration > 0 then math.clamp(elapsed / decayDuration, 0, 1) else 1
	return force * (1 - 0.5 * t)
end

return TraversalMath
