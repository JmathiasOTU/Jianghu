--!strict

-- Studio playtest capture and logging switches for movement validation
-- (docs/MovementSystem.md §10). All false in committed code: flip one for
-- a playtest, then flip it back.
local DebugFlags = {}

-- Measurement capture for the vertical ceiling (audit M-001, ARCHITECTURE §9):
-- prints how far above the ceiling a character went and for how long, every
-- time it happens. The ceiling ships with ZERO tolerance; if honest play
-- produces excesses, this capture is what sizes a documented fix -- never a
-- guessed slack constant.
DebugFlags.VERTICAL_CEILING_DEBUG_LOGGING = false

-- Measurement capture for the ceiling's launch speeds (2026-09-24): honest
-- single-press slide jumps were caught leaving the ground at ~62 studs/s
-- against JumpPower 55. On every landing this prints the flight's peak above
-- its takeoff, the time to reach it, the launch speed that implies
-- (sqrt(2 g peak)) and the mirror state it left from, so standing, running
-- and slide jumps can be told apart before any constant is changed. Studio
-- playtests only; turn it off once the numbers are recorded.
DebugFlags.JUMP_LAUNCH_CAPTURE = false

-- Measurement capture for SpeedToleranceMultiplier (audit M-007/M-015/M-016,
-- ARCHITECTURE §9): every closed speed window records how far the character
-- really moved as a fraction of the budget it was allowed (before the
-- tolerance multiplier). Honest play's p99.9 of that ratio IS the measured
-- tolerance. Windows with zero budget (WallCling) report their raw drift in
-- studs instead, which is what sizes the cling's "no drift" definition.
-- Studio playtests only; the sample list is capped.
DebugFlags.SPEED_RATIO_CAPTURE = false

-- Temporary instrumentation for the 2026-09-13 Sprint-rubber-banding
-- investigation (docs/MovementSystem.md §8) -- prints real numbers instead of guessing
-- at a tolerance. Flip on for a playtest, off for normal play; left in (not
-- deleted) since Stage 2's WallRun/etc. validation will want the same kind of
-- capture again.
DebugFlags.SPEED_SANITY_DEBUG_LOGGING = false

-- Diagnostic capture for the 2026-09-18 "WallLeap boost gets erased" bug --
-- same pattern as the other *_DEBUG_LOGGING flags above. Prints why a
-- WallRun/WallLeap claim was rejected, or why `Mirror.PassiveTransitions`
-- force-exits WallRun. Re-enabled (still 2026-09-18) after the SpeedSanity
-- rubber-band came back post-retune (WallRunSpeed 26->35,
-- WallLeapBurstForce/PushForce 14/16->75/75) -- need to confirm whether the
-- claim is being rejected again (same root cause as before) versus something
-- new, rather than guessing at a second patch on top of the first.
DebugFlags.WALL_TRAVERSAL_DEBUG_LOGGING = false

return DebugFlags
