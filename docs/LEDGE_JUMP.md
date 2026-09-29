# Ledge Jump — Design Slice

Status: **implemented 2026-09-28; `docs/MovementSystem.md` §4.10 is now the source of truth.**
Delete this file once LedgeJump is playtested. Where the two differ, §4.10 wins: the server
confirms the takeoff from its position stream (the state label leads positions, §9, so a drop
probe at label time runs from short of the edge); the edge is Airborne → LedgeJump, not Run/Sprint
→ LedgeJump; legality lives in `CanEnter[LedgeJump]` (no separate `TakeoffResolution` module); and
the launch leaves vertical speed alone rather than setting it to `JumpPower`, so a slide jump keeps
its 63.

Original status: design, no code written yet. Companion slice to `docs/MovementSystem.md` §4.3 (Airborne)
and §4.2 (Slide/SlideJump), and to Flow, `docs/MovementSystem.md` §4.9 (this is a new `FlowBuilding`
source). Depends on nothing unshipped — the slide-jump landing resume (§4.4) and Flow are both live.

Context: from the reference footage and the follow-up conversation, this isn't "vault" (that name
is already taken by `VaultState.luau` — a mantle *onto* a ledge you're short of) and it isn't a
passive "walk off an edge and get a boost" either. It's specifically: **jump (or slide-jump) right
at the edge of a drop-off while moving fast, and you get a forward burst instead of just falling
off** — a deliberate, skill-timed move, the grounded mirror of what `SlideJump`/`WallLeap` already
are for their own takeoff moments.

---

## 0. Decisions locked for this slice

| Question | Decision |
|---|---|
| Is this Vault? | **No.** Vault is "assisted climb onto a ledge you're short of." This is "assisted launch off a ledge you're standing on." Different direction, different trigger, different existing precedent to follow (`SlideJump`/`WallLeap`, not `VaultState`). Kept as a separate state so neither name gets overloaded. |
| Is this a passive "ran off an edge" trigger? | **No, confirmed with the project owner** — it fires on an actual jump input at the edge, not on merely walking off one (falling off an edge you didn't jump from stays a plain `Airborne` fall, unchanged). Also applies to a slide-jump taken right at an edge, not only a plain jump. |
| New `MovementState`? | **Yes — `LedgeJump`.** One-tick launch state, identical shape to `SlideJumpState`/`WallLeapState`: `Enter` computes a boosted velocity and hands off to `Airborne` in the same synchronous call; `Update`/`Exit` are no-ops. Not folded into `AirborneState` itself, for the same reason `SlideJump` isn't folded into `Airborne` — it needs its own topology entry, its own `FlowBuilding` membership, and its own animation slot (you said the clip already exists). |
| Trigger shape | **A new shared resolver, `TakeoffResolution.Resolve`, next to the existing `LandingResolution.Resolve`.** `RunState` and `SprintState` each already have a `not context.grounded -> Airborne` line; replace the hardcoded target with a call to this resolver (Walk and Idle keep theirs, see the next row). Landing already has one shared "what should I actually become" function used from every landing call site; leaving the ground deserves the same treatment, called identically by the server, instead of duplicating the ledge/speed/jumping check per state. |
| Where it fires | **Run and Sprint only** (designer, 2026-09-28): it's a movement move, so it needs the speed tiers you actually move at. `TakeoffResolution.Resolve` is only called from `RunState`/`SprintState` (and the server's Run/Sprint branch); Walk and Idle never call it, so a walk-jump off an edge stays a plain `Airborne`. A slide-jump taken at an edge counts too, since Slide is only reachable from Run/Sprint. |
| Gate conditions | **All three, together, on top of the Run/Sprint rule above:** (1) `context.jumping` (a real jump, from `Humanoid:GetState()`, not just losing ground support — same signal `SlideJumpState`'s own trigger already reads via `context.characterMover:IsJumping()`), (2) real speed — `characterMover:GetSpeed() >= constants.LedgeJumpMinEntrySpeed`, same "momentum is a required input, not manufactured from nothing" gate `WallRunMinEntrySpeed` already established. It reads real speed, not the tier label, so a Run that has only just started accelerating doesn't qualify yet; at 22 it sits below Run's 28, so any settled Run does, and (3) a real drop-off ahead, from a new geometry probe (§2). All three fail closed to the existing plain `Airborne` — a player with no ledge nearby, or too slow, or who didn't actually jump, sees zero behavior change. |
| Landing-resume interaction | **Reuse the fix already shipped, don't reinvent it.** `Run/Sprint -> LedgeJump -> Airborne` is a *more direct* version of the slide-jump case the landing resume fixed (`docs/MovementSystem.md` §4.4) — there's no intermediate `Slide` state obscuring which tier you launched from, since `TakeoffResolution.Resolve` is called from inside `RunState`/`SprintState`'s own `Update`, where `previous` is already known. Set `preAirborneLocomotion` right there, the same tick, rather than adding a second capture-and-carry field the way `slideEntryLocomotion` was needed for Slide. |
| Flow interaction | **`LedgeJump` joins `MovementStateGroups.FlowBuilding`** (and `FlowHolding`, since its speed is fixed at launch), same as `SlideJump`/`WallLeap`/`WallBoost`/`Vault`/`DoubleJump`. Flow only exists inside a sprint chain (`docs/MovementSystem.md` §4.9), so **a Sprint ledge jump builds Flow and a Run ledge jump doesn't**: `FlowRules.Gains` already gives exactly that with no special case. A Run ledge jump still gets its burst and resumes Run on landing. |
| Server claim? | **None — passively inferred, same precedent as `SlideJump`.** Neither a plain jump nor a slide-jump is a claimed move today; the server reaches `Airborne`/`SlideJump` purely from its own mirrored `TakeoffResolution.Resolve(context)` call, run with the server's own replicated speed and its own geometry probe. A modified client claiming a launch it didn't qualify for is simply never mirrored into `LedgeJump` server-side, so its speed gets judged against `Airborne`'s ordinary cap and corrected — the standard "server derives its own copy independently" answer (`ARCHITECTURE.md` §3), no new validation branch needed beyond teaching `SpeedCaps` about one more state. |
| Vertical height | **Unchanged from a normal jump** (`JumpPower`), only horizontal gets a burst. Keeps the vertical ceiling (§8.3) untouched — no new vertical math to validate. Flagged as tunable in §7 if a flatter "diving off the edge" arc turns out to feel better in playtest. |

---

## 1. `TakeoffResolution` — the new shared resolver

New file, `Shared/Movement/TakeoffResolution.luau`, same shape and same "pure function, called
identically by both sides" contract as `LandingResolution.luau`:

```
function TakeoffResolution.Resolve(context: MovementContext): MovementState
	if not context.jumping then
		return MovementStates.Airborne
	end
	if characterSpeedTooSlow(context) then -- context.characterMover:GetSpeed() < constants.LedgeJumpMinEntrySpeed
		return MovementStates.Airborne
	end
	if not context.ledgeDropAhead then -- populated by SpatialQueries.QueryLedgeDropAhead, §2
		return MovementStates.Airborne
	end
	return MovementStates.LedgeJump
end
```

`RunState.Update` and `SprintState.Update` change their one line from (Walk and Idle keep plain
`Airborne`; §0):

```
if not context.grounded then
	context.fsm:RequestTransition(MovementStates.Airborne, context)
```

to:

```
if not context.grounded then
	local target = TakeoffResolution.Resolve(context)
	if target == MovementStates.LedgeJump and (current == Run or current == Sprint) then
		-- set here, not in a second capture field -- see §0's landing-resume note
		-- (Movement/init.luau's own preAirborneLocomotion local, or the server's
		-- session.preAirborneLocomotion) = current
	end
	context.fsm:RequestTransition(target, context)
```

Mirrored identically in the server's own passive-transition pass (`Mirror.luau`, wherever it
currently does the equivalent `not context.grounded -> Airborne` for Run/Sprint).

---

## 2. The probe — `SpatialQueries.QueryLedgeDropAhead`

New pure function, same file, same idiom as `QueryGround`/`QueryWallRun` (a shared `RaycastParams`,
one cast, no state):

```
function SpatialQueries.QueryLedgeDropAhead(
	rootPart: BasePart,
	filterInstance: Instance,
	direction: Vector3,      -- real horizontal velocity direction, not facing --
	                         -- same "momentum decides, not the camera" choice
	                         -- WallLeap's own direction already makes
	forwardDistance: number?,
	castDistance: number?
): boolean
```

Casts one ray straight down from a point `forwardDistance` studs ahead of the root along
`direction`, to `castDistance` (bigger than `GroundQueryCastDistance`, since this needs to find
*no* ground to confirm a drop). Returns `true` only when that ray finds nothing — flat ground or a
gentle slope directly ahead means "no ledge here," same fail-closed shape every other probe in this
file uses. Two new structural constants (never tunable, per `ARCHITECTURE.md` §9 — these are cast
geometry, not a feel number): `LedgeJumpProbeForwardDistance`, `LedgeJumpProbeCastDistance`.

Populated into context exactly like `wallRunQuery` is (`docs/MovementSystem.md` §4.5): a new
`context.ledgeDropAhead: boolean` field, probed once per jump attempt (not throttled/cached like the
sustained WallRun probe — this only ever runs at the single instant `context.jumping` flips true,
never every Heartbeat), by both the client (in the same place it already builds `context.jumping`)
and the server (in its own mirrored context build, `Context.luau`).

---

## 3. Launch math — `TraversalMath.LedgeJumpVelocity`

One more pure function alongside `WallLeapVelocity`, deliberately simpler (no wall normal to push
off of):

```
function TraversalMath.LedgeJumpVelocity(
	direction: Vector3,
	currentSpeed: number,
	jumpPower: number,
	burstForce: number
): Vector3
	local forward = direction * (currentSpeed + burstForce)
	return Vector3.new(forward.X, jumpPower, forward.Z)
end
```

`LedgeJumpState.Enter` calls this with the real current horizontal velocity/direction (same
`context.characterMover:GetHorizontalVelocity()` read `WallLeapState` already uses), applies it via
the same one-shot `SetHorizontalVelocity`/`SetVerticalVelocity` pair `SlideJumpState`/`WallLeapState`
already use (never `SetVelocityOverride` — this hands off to `Airborne` in the same synchronous
call, so there's no `Exit` to ever clear a constraint), then
`context.fsm:RequestTransition(MovementStates.Airborne, context)`.

---

## 4. FSM wiring

```
Shared/FSM/MovementStates.luau          -- + LedgeJump = Symbol("LedgeJump")
Shared/Movement/StateRules.luau         -- Transitions[LedgeJump] = { Airborne }
                                            CanEnter[LedgeJump] = function(context) return not context.grounded end
                                            (identical to SlideJump's own CanEnter -- legality already
                                            lives entirely in TakeoffResolution, topology just needs
                                            an edge to exist)
Shared/FSM/MovementStateGroups.luau     -- FlowBuilding[LedgeJump] = true
```

No landing edge needed on `LedgeJump` itself — same as `SlideJump`/`WallLeap`, it never resolves a
landing directly; it hands off to `Airborne` in the same tick and `Airborne`'s own landing logic is
unchanged.

---

## 5. Server (`SpeedCaps.luau`, `TraversalClaims.luau` or wherever the equivalent airborne-allowance
raise happens for SlideJump/WallLeap today)

- `maxSpeedForState`: fold `LedgeJump` into the same bucket `Airborne`/`DoubleJump`/`WallLeap`
  already share (`constants.SprintSpeed`, times the live/held Flow multiplier per `docs/MovementSystem.md` §8.2
  — `LedgeJump` belongs in the "held multiplier" group (`MovementStateGroups.FlowHolding`) alongside `SlideJump`/`WallLeap`,
  since its speed is fixed at launch too).
- **Exact bound, not a guess:** the launch is (current speed + burst), so bound the current speed
  the way Vault does (`VaultMaxHorizontalSpeed` takes `capBefore`): the effective cap in force just
  before the launch (`SpeedCaps.EffectiveMaxSpeed`, landing grace and allowances included) plus the
  trusted floor speed, then `+ constants.LedgeJumpBurstForce`. A flat `SprintSpeed × Flow` would
  under-bound a jump taken inside the landing grace after a faster flight and correct it; it also
  covers Run and Sprint with one formula. Add `TraversalMath.LedgeJumpMaxHorizontalSpeed(capBefore,
  burstForce)`, spec-tested in `tests/specs/TraversalMath.spec.luau` alongside the
  existing bound proofs (§12 of `docs/MovementSystem.md`), and raise `airborneAllowedSpeed` to it the
  moment the mirror enters `LedgeJump` — same shape as the existing WallLeap/SlideJump raises in
  `Mirror.luau`/`TraversalClaims.luau`.

---

## 6. Animation and Flow-adjacent polish

- `LocomotionAnimator.luau`: one `self._tracks.LedgeJump = loadTrack(animator, ANIMATIONS_ROOT,
  "LedgeJump", self._trove, false)` line (matches `SlideJump`'s own line exactly) plus one branch in
  the state-to-clip lookup, shown as a transient hold like `SlideJump`/`WallLeap` already are (§6 of
  `docs/MovementSystem.md`).
- The cue table (`MovementCues.luau`, `docs/MovementSystem.md` §15.1) gets a
  `[MovementStates.LedgeJump]` row for free the same way `WallLeap`'s row already
  exists there — not needed to ship this, just noted so it isn't forgotten as a follow-up.

---

## 7. Constants (new, `MovementConstants.luau` + `MovementTuning.luau`)

| Constant | Purpose | Tunable? | Starting point |
|---|---|---|---|
| `LedgeJumpMinEntrySpeed` | Speed floor to qualify (momentum gate) | F4 | 22 (above Walk's 18, below Run's 28) |
| `LedgeJumpBurstForce` | Flat forward speed added on top of current speed | F4 | 20 |
| `LedgeJumpProbeForwardDistance` | How far ahead the drop-off probe casts from | Structural, not tunable | 3 |
| `LedgeJumpProbeCastDistance` | How far down that probe casts looking for *no* ground | Structural, not tunable | 12 |

Same four-place ritual for the two F4 ones (`docs/MovementSystem.md` §10): `MovementConstants`,
`MovementTuning.TunableConstantName`, the `network.zap` enum, a new `Row_*` in the overlay.

---

## 8. Open questions / needs a playtest

- **Does the vertical arc need its own tuning**, or does keeping `JumpPower` unchanged (§0) already
  read as "diving off a ledge"? Easiest to ship as-is and only add a `LedgeJumpUpwardForce`
  override later if flat jump height reads wrong next to the horizontal burst.
- **Interaction with `WallLeap`'s own "off a wall" burst:** the two moves now share a very similar
  shape (a jump-timed forward burst) but different triggers (wall proximity vs. a ledge probe) and
  currently can't overlap (`WallLeap` only fires from `WallRun`, `LedgeJump` only fires from a
  grounded takeoff) — worth a one-line note in `docs/MovementSystem.md`'s design-decisions table
  (§13) once shipped, same as every other "why this and not that" entry there, so a future reader
  doesn't wonder why there are two similar-looking burst mechanics.

---

## 9. Files touched

```
src/Shared/FSM/MovementStates.luau              -- + LedgeJump symbol
src/Shared/FSM/MovementStateGroups.luau         -- FlowBuilding[LedgeJump] = true
src/Shared/Movement/StateRules.luau             -- Transitions + CanEnter for LedgeJump
src/Shared/Movement/TakeoffResolution.luau      -- NEW: the leaving-the-ground resolver
src/Shared/Movement/SpatialQueries.luau         -- + QueryLedgeDropAhead
src/Shared/Movement/TraversalMath.luau          -- + LedgeJumpVelocity, LedgeJumpMaxHorizontalSpeed
src/Shared/Types/MovementTypes.luau             -- + ledgeDropAhead on MovementContext
src/Shared/Constants/MovementConstants.luau     -- 4 new constants
src/Shared/Movement/MovementTuning.luau         -- 2 new tunable names + ranges

src/Client/Controllers/Movement/States/LedgeJumpState.luau   -- NEW, mirrors SlideJumpState.luau
src/Client/Controllers/Movement/States/RunState.luau         -- TakeoffResolution + preAirborneLocomotion
src/Client/Controllers/Movement/States/SprintState.luau      -- same
src/Client/Controllers/Movement/init.luau                    -- wire LedgeJumpState into the FSM table,
                                                                  jumping/ledgeDropAhead into context
src/Client/Controllers/Movement/Presentation/LocomotionAnimator.luau -- LedgeJump track + clip branch

src/Server/Services/MovementValidationService/Mirror.luau       -- mirrored TakeoffResolution call
src/Server/Services/MovementValidationService/Context.luau      -- ledgeDropAhead probe, server-side
src/Server/Services/MovementValidationService/SpeedCaps.luau    -- LedgeJump in maxSpeedForState
src/Server/Services/MovementValidationService/TraversalClaims.luau -- airborneAllowedSpeed raise
                                                                       (or wherever SlideJump's
                                                                       equivalent raise already lives)

tests/specs/TraversalMath.spec.luau             -- LedgeJumpMaxHorizontalSpeed bound proof
tests/specs/StateRules.spec.luau                -- topology + CanEnter coverage
docs/MovementSystem.md                          -- new subsection once shipped, §13 design-decisions
                                                    entry (§8 above)
```

Nothing here touches `Vault`, `WallRun`, `WallLeap`, or `Flow`'s own core files beyond the one-line
`FlowBuilding` addition and the one-line speed-cap bucket addition — this slots in alongside the
existing launch states rather than modifying any of them.
