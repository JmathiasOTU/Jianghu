the # Wall Run / Wall Leap — Design Doc (Slice)

Status: **design, no code written yet**. This is a living doc for this slice, following the same
format as `docs/MOVEMENT.md` — update it as decisions change or numbers get tuned.

Context: WallRun/WallClimb (`TRAVERSAL-ROADMAP.md` Phase 4) was built once and **reverted
2026-09-17** — the forward-raycast entry shape (`QueryWall`, built for "wall dead ahead") never
reliably triggered on the shallow-angle approach a real wall run requires. `docs/MOVEMENT.md` §13
flags the fix direction (a side-cast along the root part's own `CFrame.RightVector`, not a
forward cast) and names the old game's `WallRunController._sampleWallHit` as the reference.

**This slice is scoped to WallRun + WallLeap only.** WallClimb and WallLatch are explicitly out of
scope — WallLatch in particular is a different system entirely per your own call, not a
sub-phase of this one. Nothing below reuses WallClimb's snap-to-wall/vertical-climb logic; where
the old (reverted) design shared a mechanism with WallClimb, this doc says so and either drops it
or narrows it to WallRun/WallLeap's own needs.

---

## 0. Decisions locked for this slice

| Question | Decision |
|---|---|
| Wall detection shape | **Shapecast** (small-radius spherecast), not a thin raycast — tolerates gaps/trim/rounded geometry, gives a cleaner averaged normal. Used for both the entry gate and the sustained per-tick check (one shape, not a cheap/expensive hybrid). |
| Latch as its own state | **No.** WallLatch is a separate system, out of scope. Two states only: `WallRun`, `WallLeap`. |
| Corners / curved walls | **Snap off past a threshold.** Tangent direction is locked at entry and never recomputed mid-run. The instant the live wall normal deviates past a documented angle from the entry normal, the run ends cleanly into `Airborne` — no continuous re-steering, no smoothing. |
| Cling/leap physics primitive | **Extend `CharacterMover:SetVelocityOverride` only.** No `AlignOrientation`/`AlignPosition`. Consequence: the "lean into the wall" read has to come from the `WallRunLeft`/`WallRunRight` animation clips themselves, not a physics-driven tilt — noted explicitly so it isn't a silently missing feature. |
| Does the character visually snap onto the wall? | **Yes — a one-time position correction at Enter, plus a small continuous hold.** Not a physics tilt, a real position nudge. Detailed in §3's new "Cling Distance" subsection. |
| Which side's animation plays | **Locked at entry, not re-read live.** `wallRunQuery.side` at the moment `WallRun` is entered decides `WallRunLeft`/`WallRunRight` for the whole run — never re-evaluated mid-run. Detailed in §1/§5. |
| How is WallRun activated | **A discrete second Space press while airborne, not Heartbeat polling.** Jump normally (grounded takeoff, unrelated to this system), then — while airborne, near a wall, moving along it — press Space again to lock on. Reuses the exact `JumpRequested` edge `DoubleJump` already listens on, tried first in priority order; falls through to `DoubleJump` if `CanEnter[WallRun]` isn't satisfied at that instant. A third press while already wall-running fires `WallLeap`. Detailed in §2/§5. Supersedes this doc's original "entry is polling" carry-over from the pre-revert design. |

---

## 1. Wall Detection — `SpatialQueries.QueryWallRun`

New pure function in `Shared/Movement/SpatialQueries.luau`, called identically by client
prediction and server resimulation (same "one geometry read, never two hand-synced copies"
principle every existing query in this module already follows).

```luau
export type WallRunQueryResult = {
	position: Vector3,
	normal: Vector3,
	side: "Left" | "Right",
}

function SpatialQueries.QueryWallRun(
	rootPart: BasePart,
	filterInstance: Instance,
	castRadius: number?,
	castDistance: number?
): WallRunQueryResult?
```

- Casts a `Shapecast` (small sphere, radius `WallRunSideCastRadius`) once along
  `rootPart.CFrame.RightVector` and once along its negation, out to `WallRunSideCastDistance`.
  Both share one `RaycastParams` (`Exclude`, filtering the caster's own character — identical
  filter idiom `QueryGround`/`QueryWall` already use).
- **Flatness check, same as the existing `QueryWall`:** a hit only counts if
  `math.abs(hit.Normal:Dot(Vector3.yAxis)) <= WallDetectMaxUpDot` — rejects a ramp, slope, or
  ceiling reading as a wall. This constant already exists from the pre-revert build; reused
  as-is, no new name needed.
- If both sides hit, the closer one wins (real geometry — e.g. a narrow alley — can have a wall
  on both sides at once; the nearer one is the one you're actually about to run along).
  If only one side hits, that's the result. If neither hits, returns `nil`.
- `side` is returned alongside `position`/`normal` because it's needed twice downstream: to pick
  `WallRunLeft` vs. `WallRunRight` in `LocomotionAnimator`, and to fix the tangent's sign (§2)
  without re-deriving it from the normal a second time.

**Side is read once, at entry, then locked for the run's lifetime — same treatment as the
tangent/normal (§2/§3).** `WallRunState.Enter` stores `entrySide = wallRunQuery.side` alongside
`entryNormal`/`entryTangent`; `LocomotionAnimator` reads `entrySide`, not a live per-tick
`context.wallRunQuery.side`. Two reasons this matters, not just consistency for its own sake:
1. In a narrow corridor with a wall on both sides, the "closer hit wins" rule (above) could
   theoretically flip which side reports closer between two ticks on noisy geometry (a seam
   between two parts, a beveled corner) — locking it at entry means the animation can never
   flicker between `WallRunLeft`/`WallRunRight` mid-run even if that happens.
2. It keeps the animation, the tangent, and the corner-deviation check all reading from the same
   one entry snapshot — one source of truth for "what wall am I on," not three independent live
   reads that could disagree with each other for a frame.

This is a **new, separate query from `QueryWall`** (the old forward-cast, ledge-oriented probe),
not a modification to it — exactly the separation the pre-revert build already reasoned its way
into (`docs/MOVEMENT.md` §13's note that `WallLatch`/`WallLeap` would read the forward `wallQuery`
while wall-running reads its own side probe). Since WallLatch is out of scope for this slice,
`QueryWallRun` is the *only* wall probe this slice needs — there is no forward `wallQuery` call
site in this design at all.

**Throttling.** Same `dt`-accumulator idiom every other spatial query in this file uses
(`WallRunQueryThrottleSeconds`), probed only while airborne:
- Client: an accumulator in `Movement/init.luau`'s Heartbeat, cleared on grounding.
- Server: an `os.clock()`-delta accumulator in `MovementValidationService.updateWallRunQuery`,
  run for every airborne session regardless of current state — it has to be live *before*
  `CanEnter[WallRun]` is ever asked, so a claim can be validated the instant it arrives, same
  reasoning `docs/ARCHITECTURE.md` §3's "sanity raycasts" requirement already establishes for
  any spatial claim.

`wallRunQuery` becomes a real field on the shared `MovementContext`
(`Shared/Types/MovementTypes.luau`), populated by each side from its own probe *before* calling
into `StateRules` — never computed inside `StateRules` itself, matching how every other
context field in this codebase is populated.

---

## 2. Tangent Direction & Entry Legality

**Tangent is derived once, at entry, from the wall normal — never from a separate "which way is
the wall running" probe.** Rotate the wall normal 90° around world up:

```luau
local tangent = Vector3.new(-normal.Z, 0, normal.X).Unit
```

This gives one of the two directions parallel to the wall. Pick the sign that agrees with the
player's own momentum, not an arbitrary convention:

```luau
if tangent:Dot(characterMover:GetHorizontalVelocity().Unit) < 0 then
	tangent = -tangent
end
```

A wall run always **continues** the direction you were already moving — it never reverses you
onto the wall backwards. This is what "carries momentum" actually means mathematically for this
mechanic: the tangent isn't a new direction the mechanic invents, it's your existing velocity
vector projected onto the wall plane.

**`CanEnter[WallRun]` (`Shared/Movement/StateRules.luau`), all four gates required together:**

1. `not context.grounded` — reachable only from `Airborne`, same family as every other traversal
   move.
2. `context.wallRunQuery ~= nil` — a real wall, read fresh this frame, not cached.
3. `characterMover:GetSpeed() >= constants.WallRunMinEntrySpeed` — you cannot wall run from a
   standstill jump. This is the mathematical expression of "momentum-driven": the mechanic
   requires momentum as an input, it doesn't manufacture it from nothing.
4. `moveIntent.direction.Unit:Dot(tangent) >= constants.WallRunEntryDotThreshold` — you have to be
   moving *along* the wall, not directly into it (that's a wall bump, not a wall run) or directly
   away from it (that's just falling). Same "comfortably admits real WASD angles" dot-threshold
   idiom `SprintForwardDeadzone`/`WALL_CLIMB_INPUT_DOT_THRESHOLD` already use elsewhere in this
   codebase — not a new pattern.

**Entry is a discrete gesture, not polling — this is the one place this slice deliberately
departs from the pre-revert design.** §13 of the reverted build reasoned there was "no natural
single input event for touching a wall" and fell back to `AirborneState.Update` calling
`RequestTransition(WallRun)` every Heartbeat while airborne. That reasoning turns out to be wrong
for this slice's intended feel: **jump, then press Space again near the wall to confirm and lock
on** *is* a natural single input event — it's the same `UserInputService.JumpRequest` edge
`InputController.JumpRequested` already exposes for `DoubleJump` (§11 of `docs/MOVEMENT.md`),
just consumed with a different priority. See §5 for the exact handler; the short version is:

```luau
lifeTrove:Connect(input.JumpRequested, function()
	local context = buildContext()
	if fsm.current == MovementStates.WallRun then
		WallLeapState.Launch(context)
	elseif not fsm:RequestTransition(MovementStates.WallRun, context) then
		fsm:RequestTransition(MovementStates.DoubleJump, context)
	end
end)
```

`WallRun` is attempted **before** `DoubleJump` on the same press — same "the stricter, more
deliberate gesture wins when both are legal" priority the pre-revert design already used for
`WallClimb` vs. `WallRun`. If `CanEnter[WallRun]` fails (no wall, wrong angle, too slow), it falls
straight through to today's unchanged `DoubleJump` attempt — a player with no wall nearby sees no
behavior change at all. The "must JUMP near the wall facing the direction you want to go" feel
isn't a separate check — it's exactly `CanEnter[WallRun]`'s existing speed/angle gates (below),
evaluated fresh at the instant of that second press.

**Confirmed 2026-09-17: `WallRun`/`DoubleJump` are mutually exclusive on this shared press, by
design.** A player airborne near a wall who presses Space gets `WallRun`, not a double jump, even
if they'd have preferred to save the air-jump — there's no way to force `DoubleJump` instead with
that same press while `CanEnter[WallRun]` is satisfied. Accepted because `WallRunSideCastDistance`
(§7) is short enough that this only ever triggers when genuinely close to a wall — "near a wall"
in the everyday sense, not "a wall exists somewhere in the level" — so the collision between the
two moves in practice should be rare and, when it happens, look like the player got what a wall
that close would suggest they wanted.

---

## 3. WallRun Physics

**One `SetVelocityOverride` call per tick, all three axes, tangent locked from entry:**

```luau
local horizontal = tangent * constants.WallRunSpeed
local velocity = Vector3.new(horizontal.X, -constants.WallRunSinkSpeed, horizontal.Z)
characterMover:SetVelocityOverride(velocity, Vector3.new(math.huge, math.huge, math.huge))
```

- **Horizontal:** locked to the entry tangent at a fixed `WallRunSpeed` — not decaying, not
  re-derived from live input, matching the "locked at entry" corner-handling decision in §0.
  (Contrast with Slide, which *is* steerable — that's a deliberate difference: Slide steers by
  looking where you want to go along the ground; a wall run's whole premise is that the wall
  itself is dictating your path, so re-steering it would fight the geometry it's riding.)
- **Vertical:** a small constant sink rate, `WallRunSinkSpeed` (e.g. a slow, controlled fall —
  not zero, not full gravity). This is the "gravity-defying" read: not floating, but falling
  much slower than a normal `Airborne` arc for as long as the wall holds. It's a deliberate tuned
  constant, not an attempt to simulate real physics, and it's named as such — consistent with
  `docs/ARCHITECTURE.md` §9's "no band-aid tolerances" rule, which is about *validation*
  tolerances, not about gameplay-feel constants like this one (every existing movement number in
  this codebase — `SlideDecayRate`, `DoubleJumpForce` — is a tuned feel constant of exactly this
  kind).
- Full `maxForce` on all three axes (unlike DoubleJump's Y-only or Slide's XZ-only override) —
  WallRun needs to own vertical *and* horizontal simultaneously, since both are dictated by the
  wall, not by `Humanoid.WalkSpeed`.

**Sustain check, every tick while in `WallRun` (reusing the same throttled `wallRunQuery` from
§1 — the query itself doesn't need a second, faster cadence; it's already probed every frame
while airborne):**

```luau
if not context.wallRunQuery then
	-- wall lost entirely
	fsm:RequestTransition(Airborne, context)
elseif TraversalMath.AngleBetween(context.wallRunQuery.normal, entryNormal) > constants.WallRunMaxNormalDeviationDegrees then
	-- corner/curve exceeded the locked-tangent budget -- snap off cleanly
	fsm:RequestTransition(Airborne, context)
elseif os.clock() - entryTimestamp >= constants.WallRunMaxDurationSeconds then
	-- duration cap
	fsm:RequestTransition(Airborne, context)
end
```

`entryNormal` is stored per-life the same way `doubleJumpUsed`/`preAirborneLocomotion` already
are (`Movement/init.luau`'s closure client-side, `PlayerSession` server-side) — set the instant
`WallRun` is entered, read every tick, cleared on exit. `TraversalMath.AngleBetween` is one more
small pure function added to the module every traversal phase already contributes to.

A mid-run landing (running along a wall that curves down into the floor) resolves directly to a
grounded state via the same `AirborneState.ResolveLandingTarget` reuse every other airborne-family
state (`DoubleJump`, the reverted `WallClimb`) already calls into — not a new landing path.

### Cling Distance — the actual "snap onto the wall"

Confirming the mechanic: yes, the intent is a real, deliberate snap, not just a velocity nudge —
without it, a player entering at an odd approach angle or an odd perpendicular distance would run
parallel to the wall while visibly floating off it or clipping into it, which is the opposite of
"looks realistic." Locked-tangent velocity alone (the block above) only controls motion *along*
the wall — it says nothing about distance *from* it. That's a second, separate correction, along
the normal axis, in two parts:

**1. A one-time position snap, on `WallRunState.Enter`, before the first velocity override is
even applied.** The shapecast hit already tells us exactly how far off the wall the character
currently is (`(rootPart.Position - hit.position):Dot(normal)`); Enter corrects that in one shot
to a fixed `WallRunClingDistance` (tuned to sit the character flush against the wall — roughly an
R6 torso-width offset, not touching/clipping):

```luau
local currentOffset = (rootPart.Position - hit.position):Dot(normal)
local correction = normal * (constants.WallRunClingDistance - currentOffset)
characterMover:NudgeIntoWall(correction)
```

This is a direct one-time position write, not a constraint — the same category of move as the
existing `RequestDevTeleport` handler, just much smaller in magnitude (a couple of studs, not a
level-spanning teleport) and fired from gameplay code instead of a dev tool. It reuses that same
precedent's consequence too: `MovementValidationService` resets its `enforceSpeedSanity` baseline
the instant `WallRun` is accepted (§6 already calls this out for the FSM-transition reason;
this position nudge is the second, physical reason the baseline reset is needed — otherwise the
delta-position check would see an instantaneous few-stud jump and flag it as a teleport hack).

**2. A small continuous hold correction, folded into the same per-tick `SetVelocityOverride` call
in §3 — not a second constraint.** Even with the Enter snap, an uneven or very slightly curved
wall surface could let the character drift a little over the run's duration. Rather than
re-snapping the position every tick (which would look like a series of micro-teleports, not a
glide), a small proportional term is added to the velocity vector's normal-axis component:

```luau
local offsetError = constants.WallRunClingDistance - currentOffset  -- + means too far, - means clipping in
local clingCorrection = normal * math.clamp(
	offsetError * constants.WallRunClingCorrectionRate,
	-constants.WallRunClingMaxCorrectionSpeed,
	constants.WallRunClingMaxCorrectionSpeed
)
local velocity = Vector3.new(horizontal.X + clingCorrection.X, -constants.WallRunSinkSpeed, horizontal.Z + clingCorrection.Z)
```

This is a standard clamped proportional (P) controller, not a spring/tween — bounded by
`WallRunClingMaxCorrectionSpeed` so a large sudden error (e.g. right after the corner-deviation
check permits a slightly different normal) never reads as a snap or a jolt, just a firm, fast
settle. Because the entry snap already zeroes the error at the start, this term does very little
work in the common case — it's a safety margin against drift, not the primary mechanism. It's
still a single `SetVelocityOverride` call, still zero new constraint types, consistent with the
§0 decision not to add `AlignPosition`.

**Net effect:** the character snaps flush to the wall the instant `WallRun` is entered (one
frame, not a visible slide-into-place), then stays flush for the whole run via a correction small
enough to be invisible under normal geometry, and only becomes visible (a firm re-settle rather
than a teleport) right after a corner that was just barely within the deviation budget in §3.

---

## 4. WallLeap

**A single-frame launch state, same shape as `SlideJump`'s boost and the reverted `WallClimb`'s
`ClimbJump`** — not a sustained hold. Triggered by the unified `JumpRequested` handler in §2: any
Space press while `fsm.current == WallRun` calls `WallLeapState.Launch(context)` directly, not
through `RequestTransition`'s ordinary `CanEnter` path, because it needs to carry a real launch
impulse, not just pick a target state — same reasoning `WallClimb.ClimbJump` already established.
That branch is checked *first* in the handler (§2), so "the press that entered WallRun" and "the
press that leaps out of it" can never be the same press — entry only ever fires the `elseif`
branch below it.

**Launch vector — one new pure function, `TraversalMath.WallLeapVelocity`:**

```luau
function TraversalMath.WallLeapVelocity(
	tangent: Vector3,
	wallNormal: Vector3,
	entrySpeed: number,
	constants: EffectiveMovementConstants
): Vector3
	local forward = tangent * math.max(entrySpeed, constants.WallRunSpeed) * constants.WallLeapForwardRetention
	local pushOff = wallNormal * constants.WallLeapPushForce
	return Vector3.new(forward.X + pushOff.X, constants.WallLeapUpwardForce, forward.Z + pushOff.Z)
end
```

Three components, each doing one job:
- **Forward retention** (`tangent * ... * WallLeapForwardRetention`) — this is what makes the
  leap read as "carrying momentum" rather than a static jump: you launch mostly *along* the
  direction you were already running, scaled by a retention fraction (≤ 1) off your actual
  run speed, not a flat re-issued constant.
- **Push-off** (`wallNormal * WallLeapPushForce`) — a fixed lateral shove away from the wall, so
  the leap actually clears the wall instead of grazing along it.
- **Upward arc** (`WallLeapUpwardForce`) — a fixed vertical component, giving the leap a real arc
  instead of a flat horizontal launch. Deliberately a flat constant, not a decaying impulse like
  `DoubleJump`'s — a wall leap is one clean launch, not a sustained float.

Called identically client- and server-side (same "pure function, no stored state, can't drift
into two hand-synced copies" principle `DoubleJumpVerticalVelocity` already established) — fed
by whatever `tangent`/`wallNormal`/`entrySpeed` **that side itself stored at WallRun's entry**,
never a value the other side reports.

**Applied via `CharacterMover:SetHorizontalVelocity` + `SetVerticalVelocity`, one-shot writes —
not `SetVelocityOverride`.** Same reasoning `SlideJumpState`/`WallClimb`'s `ClimbJump` already
established: `WallLeap` transitions to `Airborne` *synchronously* in the same call, so a
constraint-backed override would get cleared by `Exit` before the physics engine ever integrates
it. `WallRunState.Exit` clears the `LinearVelocity` override first (leaving it inert, per
`CharacterMover`'s existing "parented but inert between uses" contract), then `WallLeapState`
fires the one-shot velocity write and immediately calls `fsm:RequestTransition(Airborne, context)`
— the identical two-step shape `WallClimb.ClimbJump` used before the revert.

No separate `WallLeap` topology beyond `WallRun -> WallLeap -> Airborne`, both edges taken in the
same frame. `WallLeap` still gets its own FSM Symbol (not folded into `WallRun.Exit`) so it has a
clean name for the server claim, the debug overlay, and the animation slot — matching what you
asked for (isolated, named states) even though its runtime lifetime is one tick.

---

## 5. FSM Mapping

**New symbols** (`Shared/FSM/MovementStates.luau`): `WallRun`, `WallLeap`.

**`StateRules.Transitions` additions:**

```luau
[MovementStates.Airborne] = {
	-- ...existing entries...
	MovementStates.WallRun,
},
[MovementStates.WallRun] = {
	MovementStates.WallLeap,
	MovementStates.Airborne,
	MovementStates.Idle,
	MovementStates.Walk,
	MovementStates.Run,
	MovementStates.Sprint,
},
[MovementStates.WallLeap] = {
	MovementStates.Airborne,
},
```

The grounded targets alongside `WallRun -> Airborne` cover the mid-run-landing case (§3), the
same reason `DoubleJump`'s and the reverted `WallClimb`'s own tables carry grounded targets
alongside their primary exit.

**New modules, following the existing layout exactly:**

```
Client/Controllers/Movement/States/
    WallRunState.luau     -- Enter: store entryNormal/entryTangent/entrySide/entryTimestamp,
                              fire the one-time NudgeIntoWall cling snap (§3), apply first
                              SetVelocityOverride. Update: re-shapecast, corner/duration/lost
                              checks (§3), re-apply the locked-tangent + cling-correction
                              override every tick. Exit: ClearVelocityOverride.
    WallLeapState.luau    -- Enter only: compute TraversalMath.WallLeapVelocity from the
                              WallRunState-stored entry values, one-shot write, synchronous
                              RequestTransition(Airborne). No Update/Exit body needed -- same
                              shape as the reverted WallClimb's ClimbJump, not a full state
                              lifecycle.
```

**`AirborneState` itself needs no changes** — no polling, per §2/§0's decision. Instead,
`Movement/init.luau`'s existing `input.JumpRequested` connection (currently a single
unconditional `RequestTransition(DoubleJump, context)`) is restructured into the three-way
priority handler from §2:

```luau
lifeTrove:Connect(input.JumpRequested, function()
	local context = buildContext()
	if fsm.current == MovementStates.WallRun then
		WallLeapState.Launch(context)
	elseif not fsm:RequestTransition(MovementStates.WallRun, context) then
		fsm:RequestTransition(MovementStates.DoubleJump, context)
	end
end)
```

No explicit "currently Airborne" guard needed anywhere in this chain — topology alone gates it,
same reasoning `DoubleJump`'s original unconditional trigger already relied on: `CanEnter[WallRun]`
requires `not context.grounded`, so a grounded Space press (an ordinary jump takeoff, handled
entirely by Roblox's own Humanoid jump — unrelated to this FSM) fails both the `WallRun` and
`DoubleJump` attempts harmlessly and falls through to nothing, exactly as it does today.

`ClientMovementContext` needs no new fields beyond `wallRunQuery` (§1) — `entryNormal`/
`entryTangent`/`entrySide`/`entryTimestamp` are `WallRunState`'s own per-life closure state, not
shared context, exactly like `doubleJumpUsed` is `Movement/init.luau`'s closure state rather than
a `MovementContext` field.

**`CharacterMover`** gains exactly **one** new primitive: `NudgeIntoWall(offset: Vector3)` — a
direct, one-shot `PivotTo` position translation (`character:PivotTo(character:GetPivot() +
CFrame.new(offset))`, moving the whole model, not a bare `rootPart.CFrame` write, so Motor6D-welded
limbs never desync) for the Enter-time cling snap (§3). This keeps "states never touch the
Humanoid/RootPart/Model directly" (`docs/MOVEMENT.md` §4) intact — `WallRunState` calls
`characterMover:NudgeIntoWall(...)`, never the model itself. Everything else —
`SetVelocityOverride`/`ClearVelocityOverride` (used by `WallRunState`'s continuous hold) and
`SetHorizontalVelocity`/`SetVerticalVelocity` (used by `WallLeapState`) — already exists and needs
no changes. Still zero new constraint types (`AlignOrientation`/`AlignPosition`), per §0 — the
snap is a position write, not a held constraint.

**Animation:** `LocomotionAnimator` picks `WallRunLeft`/`WallRunRight` off `WallRunState`'s locked
`entrySide` (§1) — read once at Enter, not `context.wallRunQuery.side` live. The slots already
exist in `Assets/Animations/Movement.model.json` from the reverted build. `WallLeap` gets wired as
a brief one-shot overlay on launch (same "one-shot hold" idiom `Land`/`SlideJump` already use,
since the state itself only lives one tick). `WallLatch`'s existing slot is left alone — out of
scope per §0.

---

## 6. Network & Server Validation

**Claimed, not passively mirrored** — same model `DoubleJump` established, not `Slide`'s
dwell-free passive-mirror model, because both `WallRun`'s sustained hold and `WallLeap`'s launch
impulse are real physics claims a modified client could otherwise fake outright.

`network.zap`'s `ClaimableTraversalMove` enum gains `"WallRun"` and `"WallLeap"`, using the
existing `ClaimTraversalMove` event — no new event needed. `DebugMovementState` gains the same
two names for the F4 overlay, mirrored in `MovementStateNames.DebugNames`.

**`MovementValidationService.onClaimTraversalMove`, two new branches:**

- **`"WallRun"`:** recompute `CanEnter[WallRun]` using the server's **own** `wallRunQuery`
  (`updateWallRunQuery`, §1) and the server's own `GetHorizontalVelocity()` reading — never a
  client-asserted normal, tangent, or speed. Reject if illegal. On accept: store
  `entryNormal`/`entryTangent`/`entryTimestamp` in `PlayerSession`, from the server's own values
  only, and reset the `enforceSpeedSanity` baseline (same "reset the baseline, don't pad the
  tolerance" approach `docs/MOVEMENT.md` §5's rubber-banding fix and the dev-teleport fix already
  use for a legible state change).
- **`"WallLeap"`:** legal only if `session.fsm.current == MovementStates.WallRun` (topology
  itself is the entire legality check — there's no separate `CanEnter[WallLeap]` predicate
  beyond "you have to actually be wall-running"). On accept, transition the mirror to `WallLeap`
  then immediately to `Airborne`, matching the client's own synchronous two-step. The server does
  **not** re-derive or push its own velocity vector onto the character — Roblox's own network
  ownership model keeps the player's character physics client-authoritative, the same as every
  other movement move in this codebase; the server's job is legality plus the anti-exploit
  measures below, not re-simulating the launch itself.

**`mirrorPassiveTransitions`, one new branch — this is the actual anti-exploit backbone, not the
claim gate above:**

```luau
if current == MovementStates.WallRun then
	local query = session.wallRunQuery
	if not query
		or TraversalMath.AngleBetween(query.normal, session.wallRunEntryNormal) > constants.WallRunMaxNormalDeviationDegrees
		or os.clock() - session.wallRunEntryTimestamp >= constants.WallRunMaxDurationSeconds
	then
		session.fsm:RequestTransition(MovementStates.Airborne, context)
	end
end
```

This runs **every server Heartbeat for the duration of the hold**, off the session's *own*
`wallRunQuery`/entry timestamp, never anything the client claims or reports. It is the answer to
"what stops infinite wall-running or fly-hacking through a modified client": even a client that
never sends another packet, or that lies about still being on a wall, gets force-mirrored to
`Airborne` the instant the server's *own* shapecast says the wall is gone, the corner budget is
exceeded, or the duration cap is hit — completely independent of what the client-side FSM thinks
is happening. This is the same shape the reverted `WallClimb`'s wall-lost detection already used
(`docs/MOVEMENT.md` §13), narrowed to WallRun's three real exit conditions.

**Speed sanity — deliberately *not* a blanket suspension window.** `DoubleJump`'s brief impulse
gets a full `enforceSpeedSanity` suspension for its short decay window (`speedSanitySuspendedUntil`)
because it's over in a fraction of a second. `WallRun` is sustained — suspending the whole check
for its entire duration would open exactly the "fly however fast you want while the state claims
WallRun" hole this feature has to close. Instead:

- `maxSpeedForState` gains a `WallRun -> WallRunSpeed` entry, same table `Run`/`Sprint`/`Slide`
  already populate — the check stays **live** throughout the hold, just with the cap raised to
  the mechanic's own tuned speed, not exempted.
- `WallLeap`'s one-shot launch *does* get a short suspension window (`speedSanitySuspendedUntil`,
  same mechanism DoubleJump already uses) sized to cover the single frame the impulse needs to
  register, exactly like DoubleJump's own carve-out — a one-tick spike, not a sustained
  exemption.

**Rate limiting:** the existing `traversalRateLimiter` budget (`Shared/Util/RateLimiter.luau`)
already shared by `DoubleJump` covers `WallRun`/`WallLeap` claims too — no new limiter, same
reasoning `docs/MOVEMENT.md` §11 already gives for reusing it. Worth noting explicitly: because
entry is now a discrete `JumpRequested` press (§2) rather than a Heartbeat poll, `ClaimTraversalMove`
only ever fires once per actual Space press, never once per frame while airborne — a real
reduction in claim volume over the pre-revert polling design, not just a client-side simplification.

**Why this doesn't false-flag legitimate players (`docs/ARCHITECTURE.md` §9):** every check above
is a real, documented, measured cutoff — a geometric angle, a fixed duration, a tuned speed cap —
never an arbitrary tolerance padded to paper over latency. Latency is handled the same way the
Run/Sprint dwell check already handles it: the server validates everything against **its own**
clock and **its own** shapecast, never a client-reported timestamp or normal, so a legitimate
high-ping player's inputs simply arrive later — what's legal never changes, only when the server
finds out about it.

---

## 7. New Constants (`MovementConstants.luau`, live-tunable via the existing F4 pipeline)

| Constant | Purpose |
|---|---|
| `WallRunSideCastRadius` | Shapecast sphere radius for `QueryWallRun`. |
| `WallRunSideCastDistance` | Structural (raycast/shapecast reach) — excluded from live tuning, same treatment as `GroundQueryCastDistance`. **Dual role, confirmed 2026-09-17:** since `WallRun`/`DoubleJump` share one Space press (§2) and `WallRun` wins whenever `CanEnter` passes, this distance is also the thing that keeps that priority from stealing a `DoubleJump` press unintentionally — it has to stay short enough that `CanEnter[WallRun]` only ever passes when you're genuinely close enough to a wall to mean it, not merely "a wall exists somewhere nearby." **Revised 2026-09-18 (3.5 → 6), superseding the "err short, not generous" guidance below:** confirmed via `WALL_TRAVERSAL_DEBUG_LOGGING` that 3.5 was rejecting legitimate entries server-side — Roblox's own replication cadence for a fast-moving client-owned part lags the server's view of position by more than that at real `WallRunSpeed` values, independent of network latency, and no amount of "query fresher" server-side code can outrun it. Widening is safe here specifically because `WallRunMinEntrySpeed`/`WallRunEntryDotThreshold` are the actual primary defense against stealing a `DoubleJump` press, not this distance — a player merely double-jumping near a wall isn't also moving fast and aimed along its tangent by coincidence. |
| `WallDetectMaxUpDot` | Flatness gate — reused as-is from the pre-revert build, no new name. |
| `WallRunQueryThrottleSeconds` | Probe cadence while airborne. |
| `WallRunMinEntrySpeed` | Momentum gate — no wall run from a standstill. |
| `WallRunEntryDotThreshold` | How aligned with the wall's tangent your input must be to enter. |
| `WallRunSpeed` | Locked horizontal speed while running. |
| `WallRunSinkSpeed` | Controlled vertical sink rate (the "gravity-defying" tuning knob). |
| `WallRunClingDistance` | Target perpendicular distance from the wall surface — the actual "snap" magnitude (§3). |
| `WallRunClingCorrectionRate` | P-controller gain for the continuous hold correction (§3). |
| `WallRunClingMaxCorrectionSpeed` | Clamp on the hold correction so a post-corner re-settle is firm, never a jolt (§3). |
| `WallRunMaxNormalDeviationDegrees` | Corner/curve snap-off budget (§0/§3). |
| `WallRunMaxDurationSeconds` | Hold duration cap. |
| `WallLeapForwardRetention` | Fraction of run speed carried into the leap's forward component. |
| `WallLeapPushForce` | Fixed lateral push-away-from-wall magnitude. |
| `WallLeapUpwardForce` | Fixed vertical arc magnitude. |

`WallRunSideCastDistance` aside, all of these are real studs/second/degree/second magnitudes with
no natural default — same gap `DoubleJumpForce`/`WallRunSpeed`(pre-revert) already filled for
their own moves. Starting-point "fast and fluid" values, not measured — playtesting/tuning is
explicitly a follow-up, not blocking this design.

---

## Open questions / not decided yet

- Exact starting numeric values for the table above — propose a first pass once state modules are
  scaffolded, tune from there.
- Whether `WallLeap` should be able to chain into `DoubleJump` (topology currently doesn't allow
  it — `WallLeap`'s only exit is `Airborne`, and `Airborne -> DoubleJump` would then be available
  normally from there, same as any other airborne moment; worth confirming that's the intended
  feel rather than a dedicated `WallLeap -> DoubleJump` edge).
- Qinggong/stamina gating — `context.qinggong` still defaults to `math.huge` on both sides
  per the project's own still-open resource decision; this slice doesn't gate on it, consistent
  with "nothing below the resource's own decision blocks on it."
