# Traversal Roadmap — Qinggong Movement Expansion

> **Historical record, added to the repo 2026-09-24** (audit M-026). About 50 code comments cite this planning doc's sections. It had never been committed, so those references were unresolvable. It is **not** kept current. Several plans here changed during implementation, and Dash/WallClimb/Vault were never built. See `JIANGHU_MOVEMENT_AUDIT.md` §8 for the current state.

**Status:** Planning doc, not yet built. Companion to `docs/MOVEMENT.md` — read that
first for the existing Phase 1 FSM (Idle/Walk/Run/Sprint/Airborne/Crouch*/Slide/
SlideJump) this plan extends, not replaces.

**Scope:** Five new traversal states — `DoubleJump`, `Dash`, `WallRun`, `WallClimb`,
`Vault` — plus a full physics rebuild of the existing `Slide`/`SlideJump` pair.
Modeled on a third-party reference controller (`MovementController.luau`,
user-supplied, 1630 lines), adapted to this codebase's constraints
(`docs/ARCHITECTURE.md`), never ported directly.

**Read this before implementing anything below, human or AI:** every formula in
this document is restated as a general algorithm — clamp/dot/cross-product math,
decay curves, ratios — not copied source. If you're an AI assistant picking this
doc up to write code from, treat the formulas here as the spec and write fresh
Luau against this codebase's own patterns (`CharacterMover`, `Trove`,
`StateRules`, `MovementConstants`). Do not transcribe or closely paraphrase the
original reference file's code, even if it's attached alongside this doc — see
§11.

---

## 0. Decisions Locked In (2026-09-14)

| Decision | Answer | Rationale |
|---|---|---|
| Physics primitive | `LinearVelocity` for velocity, `AlignOrientation` for facing | Modern constraint pair, replaces the reference's deprecated `BodyVelocity`/`BodyGyro` |
| Position holds (Climb snap, Vault windup-lerp) | `AlignPosition` added as a third leg | Neither `LinearVelocity` nor `AlignOrientation` solves "stick to this point in space" — faking it out of zero-velocity damping is worse than using the constraint built for it. Flag if you'd rather stay velocity-only. |
| Slide vs. reference's slope-slide | **Replace/upgrade existing `SlideState`** | No naming collision to manage — `Slide`/`SlideJump` keep their names |
| Server validation depth | **Full trajectory resimulation** | Shared deterministic math module, server replays from its own entry snapshot — see §7 |
| Dash's FSM seam | New dedicated states, not the reserved `Overridden` seam | `Overridden` is combat's future hook for *forcing* movement (e.g. a parry counter-launch); Dash is player-initiated core movement identity (`ARCHITECTURE.md` §1), a different caller and trust model |
| Qinggong resource backing | **Still open** — wired as an abstracted `context.qinggong` field so gating works today and can point at the `Qi` profile stat (or a separate pool) later without a rewrite | Your call to make later; not blocking |

---

## 1. New FSM Symbols

Add to `Shared/FSM/MovementStates.luau`:

```
DoubleJump, Dash, WallRun, WallClimb, Vault
```

`Slide` and `SlideJump` are unchanged as Symbols — only their internal
implementation changes (§6.5).

---

## 2. CharacterMover Interface Expansion

`CharacterMover` currently only ever touches `WalkSpeed`/`JumpPower`. It grows
four new capabilities. **Each backing constraint is created once per character
life in `CharacterMover.new`, Trove-owned, and left parented but inert
(zero-force/disabled) between uses** — never re-instanced per move. This is the
single biggest structural fix over the reference, which does
`Instance.new("BodyVelocity")` per dash and lets `Debris`/manual `:Destroy()`
calls churn instances constantly (`ARCHITECTURE.md` §6).

| Method | Backing constraint | Used by |
|---|---|---|
| `SetVelocityOverride(velocity: Vector3, maxForce: Vector3?)` | `LinearVelocity` | DoubleJump, Dash, WallRun, Vault launch, Slide |
| `ClearVelocityOverride()` | — | all of the above, on Exit |
| `SetOrientationOverride(cframe: CFrame)` | `AlignOrientation` | Dash facing, WallClimb, Vault windup |
| `ClearOrientationOverride()` | — | all of the above, on Exit — hands facing back to `FacingController` |
| `SetPositionHold(target: Vector3)` | `AlignPosition` | WallClimb snap, Vault windup-lerp |
| `ClearPositionHold()` | — | on Exit |
| `GetVerticalVelocity(): number` | reads `rootPart.AssemblyLinearVelocity.Y` | Landing-severity classification (§8, Phase 0) |

`GetVerticalVelocity` mirrors `GetSpeed`'s existing doc comment exactly, just
the `Y` component instead of the flattened `X`/`Z` — a real instant-in-time
read, not a nominal constant. Added as a proper interface method rather than
a direct `rootPart` read from the presentation layer, since fall speed is the
kind of thing that plausibly graduates from cosmetic (landing animation
choice) to gameplay-relevant (a future fall-damage or landing-recovery lock)
— keeping it behind `CharacterMover` now avoids a retrofit later.

**Facing conflict to design around:** the reference forces `Root.CFrame`
directly every tick during Dodge/Flashstep. That fights `FacingController`'s
`AutoRotate`/lock-state logic (three bugs already fixed there per
`MOVEMENT.md` §4). Every new state must request orientation through
`SetOrientationOverride` and call `ClearOrientationOverride` on Exit — never
touch `Root.CFrame` or `Humanoid.AutoRotate` directly.

---

## 3. New Shared Modules

- **`Shared/Movement/SpatialQueries.luau`** — pure functions,
  `(rootCFrame: CFrame, whitelist: {Instance}) -> QueryResult?`. Houses the
  ported wall/ledge/ground raycasts (§9, mechanics 4–6). Called identically by
  client prediction and server resimulation — this is load-bearing for the
  "full trajectory resimulation" decision: resimulation only agrees with the
  client if both sides run the *literal same* geometry function, not two
  hand-synced copies.
- **`Shared/Movement/TraversalMath.luau`** — pure functions,
  `(state: MovementState, intent: MoveIntent, dt: number, query: QueryResult?, constants) -> velocityDelta: Vector3`.
  One function per new state. Client and server both call these; never
  duplicate the formula on each side.
- **`context.qinggong`** — added to `MovementTypes.MovementContext` alongside
  `crouchHeld`, same "both sides build it from their own session's source
  before calling into `StateRules`" pattern already used for `constants`.
  Initial source: a flat per-session number, server-authoritative, replicated
  down for UI — swap the source later without touching any `CanEnter`
  predicate that reads it.

---

## 4. StateRules Additions (sketch — finalize exact topology during implementation)

**Topology:**
- `DoubleJump` — reachable only from `Airborne` (needs to already be airborne; consumes the one midair jump)
- `Dash` — reachable from any grounded locomotion state (`Idle`/`Walk`/`Run`/`Sprint`/`CrouchIdle`/`CrouchWalk`) plus `Airborne`
- `WallRun` — reachable only from `Airborne`
- `WallClimb` — reachable from `Airborne` and `WallRun`
- `Vault` — reachable only from `Airborne` (including from `WallRun`/`WallClimb`, which are airborne-adjacent)
- `Vault` and `WallClimb`'s jump-off transition into `Airborne` (not directly to a grounded state) — landing resolution is already `AirborneState.Update`'s job, no special-casing needed, same principle already documented for `Slide`'s crouch hand-off
- **Correction:** `DoubleJump`'s own exit wasn't specified above — it hands back to `Airborne` once its impulse ends (the character is still airborne, just with new velocity), same as `Dash`/`WallRun` if still airborne when their own impulse/hold ends. This isn't optional polish: every traversal move that can end mid-air must route back through `Airborne` on the way down, or it silently bypasses whatever `Airborne` is responsible for — concretely, the `Fall` animation and landing-severity check added in Phase 0 (§8) below.

**CanEnter, in the same spirit as existing predicates:**
- `WallRun`/`WallClimb`/`Vault`: `not context.grounded and context.qinggong > 0 and <SpatialQueries result present>`
- `Dash`: `context.qinggong >= DashQinggongCost` (no grounded requirement)
- `DoubleJump`: `not context.grounded and not context.doubleJumpUsed` (a per-life flag, reset on landing — mirrors the reference's "resets once grounded" cooldown, minus its raw 5-second timer, which was compensating for the reference having no clean per-life reset hook)

---

## 5. New Constants (`MovementConstants.luau`, PascalCase — matches existing keys)

| Constant | Used by | Reference origin |
|---|---|---|
| `DoubleJumpForce` | DoubleJump | mechanic 2 |
| `DoubleJumpDecayDurationSeconds` | DoubleJump | mechanic 2 |
| `DashForce` | Dash | mechanic 1 |
| `DashDurationSeconds` | Dash | mechanic 1 |
| `DashAirMomentumMultiplier` | Dash (air variant) | mechanic 1a |
| `DashAirMomentumCap` | Dash (air variant) | mechanic 1a |
| `WallDetectRayLength` | WallRun, WallClimb | mechanic 4 |
| `WallDetectMaxUpDot` | WallRun, WallClimb | mechanic 4 |
| `WallRunMaxDurationSeconds` | WallRun | new (reference has no run-hold cap; Qinggong drain should own this instead of a hard timer, but keep as a safety ceiling) |
| `WallClimbSnapDistance` | WallClimb | mechanic 5 |
| `WallClimbJumpForce` | WallClimb (ClimbJump) | mechanic 5a |
| `LedgeDetectRayLength` | Vault | mechanic 6 |
| `VaultMomentumHorizontalRetention` (0.4 in reference) | Vault | mechanic 6a |
| `VaultMomentumVerticalDivisor` (3 in reference) | Vault | mechanic 6a |
| `VaultLaunchHorizontalForce` | Vault | mechanic 6a |
| `VaultLaunchVerticalForce` | Vault | mechanic 6a |
| `SlideSlopeAngleThresholdDegrees` (5° in reference) | Slide | mechanic 3 |
| `SlideMaxWalkableSlopeDegrees` (8° in reference) | Slide | mechanic 3 |
| `SlideSlopeAmplificationCap` (45 in reference, tune down) | Slide | mechanic 3 |
| `SlideGroundRaycastThrottleSeconds` | Slide | new — reference runs its raycast raw every `RenderStepped`; `ARCHITECTURE.md` §6 requires a delta-time accumulator instead |
| `TraversalSpeedSanityGraceSeconds` | server resim (§7) | new — the exemption-window gap `MOVEMENT.md`'s `Deferred` section already flagged |
| `HardLandingFallSpeedThreshold` | Landing anim (§8, Phase 0) | new — no reference source, original design |
| `LandingAnimationHoldSeconds` | Landing anim (§8, Phase 0) | new — no reference source, original design |

All of these route through `Shared/Movement/MovementTuning.luau` and get a
`lowerCamel` entry in `network.zap`'s `TunableConstantName` enum and
`TuningState` struct, same mapping pattern already used for the existing
constants.

---

## 6. Network Events (`network.zap` additions)

- **`ClaimTraversalMove`** — `Client -> Server, Reliable, SingleAsync`. Fired
  once at move-start. Payload: `state: enum{DoubleJump, Dash, WallRun,
  WallClimb, Vault}`, plus the client's detected spatial query result
  (wall/ledge position + normal) for `WallRun`/`WallClimb`/`Vault` — **the
  server independently re-runs `SpatialQueries` against its own `workspace`
  and never trusts this payload as-is**, it's only a hint for which surface to
  check.
- **`TraversalInput`** — `Client -> Server, Unreliable, SingleAsync`. A
  per-tick timestamped intent stream for the duration of a claimed move
  (`MoveIntent` + `os.clock()`-relative timestamp). This is new — the existing
  `RequestMovementTransition` model is a one-shot claim, but resimulation needs
  continuous input to replay against.
- **`TraversalReconciliation`** — `Server -> Client, Unreliable, SingleSync`.
  Snap-correction broadcast when resimulated and replicated position diverge
  past tolerance (§7.4) — reconcile, don't hard-reject the whole move.
- Extend `ClaimableMovementState` and `DebugMovementState` enums with the five
  new states, same as the existing nine.
- Extend `TunableConstantName`/`TuningState` with the constants from §5.

Every new claim/input event gets its own `RateLimiter` entry
(`Shared/Util/RateLimiter.luau`), independent of the resource gate — same
orthogonal pattern `Run`/`Sprint` already use.

---

## 7. Server-Side (`MovementValidationService.luau`) Additions

1. **`PlayerSession` gains**: per-move cooldown timestamps, `doubleJumpUsed`
   flag (reset on the server's own grounded-transition mirror), and an entry
   snapshot (`position`, `velocity`, `os.clock()`) captured the instant a
   `ClaimTraversalMove` is accepted.
2. **Resimulation loop**: on each `TraversalInput`, call the *same*
   `Shared/Movement/TraversalMath` function the client used, seeded from the
   server's own entry snapshot — never the client-reported position — same
   lag-compensation principle the parry system already uses
   (`ARCHITECTURE.md` §4), applied to traversal instead of combat timing.
3. **Cost control**: only run resimulation for a session while it's actually
   claimed into one of these five states — never a blanket per-Heartbeat cost
   for every player, same throttling philosophy as
   `SpeedCheckIntervalSeconds`.
4. **`enforceSpeedSanity` exemption window** (closes the gap `MOVEMENT.md`'s
   `Deferred` section flagged): the moment a `ClaimTraversalMove` is accepted,
   reset the speed-sanity baseline and suspend the check for
   `TraversalSpeedSanityGraceSeconds`, then resume against the resimulated
   position rather than the pre-move baseline. Without this, every legitimate
   Dash/Vault rubber-bands itself the instant it lands.
5. **`maxSpeedForState` becomes a formula for `Slide`**, not a single tier
   lookup: `baseTier + slopeAmplification(angle)`, since slide speed is now a
   continuously slope-modulated `LinearVelocity` magnitude instead of a fixed
   constant.
6. **Network ownership (`ARCHITECTURE.md` §11) — confirmed inapplicable, not
   silently skipped.** That rule governs parts the server treats as ground
   truth (hitbox proxies, projectiles), which need ownership explicitly
   pinned. Every constraint this plan adds (`LinearVelocity`, `AlignOrientation`,
   `AlignPosition`) lives on the player's own `HumanoidRootPart`, which Roblox
   already assigns network ownership of to that player by default — the same
   ownership every existing `WalkSpeed`-driven state already relies on. This
   plan introduces no new independently-owned parts, so §11 has nothing new to
   pin here. If a future move ever needs a world-space part the server must
   trust independent of the player (e.g. a persistent wall-run rail), that's
   the trigger to revisit this.

---

## 8. Build Order

**Phase 0 (Landing/Falling) → DoubleJump → Dash → Slide upgrade →
WallRun/WallClimb → Vault.** Each phase lands its slice of
`TraversalMath`/`SpatialQueries`/resimulation plumbing before the next phase
leans on it.

### Phase 0 — Landing & Falling Animation
Not Qinggong-specific — this closes an existing gap in the *current* Phase 1
`Airborne` state, which has zero animation today
(`LocomotionAnimator`'s own comment already marks this: "Jump/fall animations
aren't part of this pass — add clips for these here once they exist"). Doing
it first means every phase below inherits working landing feedback for free,
since every new traversal move that can end mid-air routes back through
`Airborne` on the way down (§4). **No new FSM states, no new network
events** — this is entirely presentation-layer (`LocomotionAnimator`), no
gameplay logic involved.

- **Rising vs. falling**, while in `Airborne`: `Humanoid:GetState()` already
  distinguishes `Jumping` (the ascent) from `Freefall` (the descent) — the
  same read `CharacterMover:IsJumping()` already does for `SlideJump`'s entry
  gate. `LocomotionAnimator` needs to hold onto `humanoid` (it already
  receives it in `.new`, just needs to store it) and branch on that each
  frame: `Jumping` → `Jump` key, `Freefall` → `Fall` key (looped — a fall can
  last arbitrarily long).
- **Landing**, on the `Airborne -> {Idle, Walk, Run, CrouchIdle, CrouchWalk}`
  edge: subscribe to the FSM's existing `changed` signal (already
  `Trove`-owned, no new coupling) and watch for `previous == Airborne`. At
  that instant, read `CharacterMover:GetVerticalVelocity()` and compare
  against `HardLandingFallSpeedThreshold` — below it, play a light `Land`
  one-shot; above it, `LandHard`.
- **The one-shot needs to win over the state's own key for a fixed window**
  (`LandingAnimationHoldSeconds`): by the time the `changed` edge fires, the
  FSM has already transitioned to `Idle`/`Walk`/etc., so `_update`'s normal
  per-state resolution would immediately pick that state's own key the same
  frame and the landing clip would never be seen. Needs a landing-hold check
  at the very top of `_update` that overrides the state-based key until the
  window elapses, then falls through to normal resolution.
- **`loadTrack` needs a `looped` parameter** — every existing slot is
  `Looped = true` unconditionally; `Jump`/`Land`/`LandHard` are one-shots,
  `Fall` stays looped.
- **New slots** in `Assets/Animations/Movement.model.json`: `Jump`, `Fall`,
  `Land`, `LandHard` — flat, non-directional, same shape as `Idle`/`Run`/
  `Sprint` (no 8-directional variants needed here the way `Walk` has).
- **`SlideJump` has the same gap** (`LocomotionAnimator`'s comment notes it
  has no clip either). One-line extension once `Jump` exists — have it reuse
  the same key. Flag if you'd rather leave it clip-less for now; not required
  for this phase.

Math: none ported — the reference file references a `Land` animation track
(used as a gate check elsewhere, e.g. not playing the sprint anim while it's
active) but doesn't define the logic that decides when to play it or how
hard. This phase is original design, not an extraction — see §9's note.

### Phase 1 — DoubleJump
Simplest of the five: a decaying vertical `LinearVelocity` impulse, gated by
"already airborne + air-jump not yet used." No raycasting needed. **Good
proof-of-concept for the new `CharacterMover` primitives and the
`ClaimTraversalMove`/resimulation plumbing** before Phase 4/5's raycasting
complexity gets layered on.
Files: `MovementStates`, `StateRules`, `MovementConstants`, `network.zap`,
new `States/DoubleJumpState.luau`, `CharacterMover` velocity-override methods,
`MovementValidationService` resim wiring.
Math: mechanic 2 in §9.

### Phase 2 — Dash
Camera/input-relative `LinearVelocity` impulse, decayed in `Update(dt)` the
same way `SlideState` already decays speed — **not** `TweenService`/
`NumberValue` instances, which is how the reference does it.
Files: new `States/DashState.luau`, `SetOrientationOverride` wiring, `Shared/Movement/TraversalMath` gets its first real entry.
Math: mechanics 1, 1a in §9.
Deferred from this phase (flag if wanted): the reference's mid-dash
dodge-cancel input window (mechanic 1b) — adds real input-handling complexity
for a polish feature, not core to the Qinggong feel.

### Phase 3 — Slide (upgrade existing)
`Enter` reads a real ground-normal raycast instead of inheriting a `WalkSpeed`
number. `Update` throttles that raycast via a delta-time accumulator
(`SlideGroundRaycastThrottleSeconds`) instead of running it raw every tick.
Keeps the **existing clean `dt`-integrated linear decay** — not the
reference's elapsed/Decay-ratio tween — and adds slope amplification on top.
`SlideJump` starts reading Slide's real `LinearVelocity` at jump-time instead
of a nominal speed constant.
Files: `SlideState.luau`, `SlideJumpState.luau`, `SpatialQueries` gets its
ground-raycast entry, `MovementValidationService.maxSpeedForState` formula
change (§7.5).
Math: mechanic 3 in §9.

### Phase 4 — WallRun + WallClimb
Both gate on the same wall-detection raycast (mechanic 4). `WallRun` projects
velocity onto the wall's tangent plane each tick; `WallClimb` holds position/
orientation via `AlignPosition`+`AlignOrientation` instead of driving
velocity, plus a `ClimbJump` vertical impulse to exit.
Files: new `States/WallRunState.luau`, `States/WallClimbState.luau`,
`SpatialQueries` gets the wall-detection entry, `SetPositionHold` wiring.
Math: mechanics 4, 5, 5a in §9.

### Phase 5 — Vault
Ledge-detection raycast (mechanic 6), a single graduated height probe
replacing the reference's 3-tier magic-number lookup, launch impulse with
ported momentum-inheritance formula (mechanic 6a) — now named constants
instead of literals.
Files: new `States/VaultState.luau`, `SpatialQueries` gets the ledge-detection
entry.
Math: mechanics 6, 6a in §9.

---

## 9. Math Reference Appendix

Formulas restated in general terms — not copied source. Reference column
points at the original function name and line range in the uploaded
`MovementController.luau`, for traceability, not for transcription.

| # | Mechanic | Formula (generalized) | Reference source | Adaptation needed |
|---|---|---|---|---|
| 1 | Dash directional impulse | velocity = cameraRelativeDirection × currentForce, where currentForce decays from an initial magnitude toward a lower floor over the move's duration | `Dodge`, lines 253–503 | Replace the `NumberValue`+`TweenService` decay with a `dt`-integrated decay inside `Update`, same pattern as `SlideState` |
| 1a | Air-dash momentum boost | boostMagnitude = clamp(priorVelocityMagnitude × 1.5, 0, cap) | `Flashstep`, lines 133–251 (air branch ~187–196) | Named constants (`DashAirMomentumMultiplier`, `DashAirMomentumCap`) instead of literals `1.5`/`60` |
| 1b | Dodge-cancel input window (deferred) | a short input-listen window (~0.2s) that, if a cancel input fires, plays a cancel animation and ends the move early | `Dodge`, lines 359–401 | Not scheduled until Phase 2 is stable; would need its own claim/ack round-trip to be server-legal |
| 2 | Double jump vertical impulse | velocity.Y = initialForce, decaying to roughly half over a short fixed duration | `DoubleJump`, lines 505–614 | Decay via `Update(dt)`, not a tween |
| 3 | Slope-aware slide decay | currentForce(t) = floorForce + (peakForce − floorForce) × clamp(elapsed / decayConstant, 0, 1) | `Slide`/`SlideData`, lines 1459–1627 | **Not ported as-is** — replaced with the existing `SlideState`'s `dt`-integrated linear decay per the locked-in decision; only the *slope amplification* and *uphill/downhill classification* below are ported |
| 3a | Slope angle | angle = acos(clamp(groundNormal · up, −1, 1)) | `Slide` (`activeSlideConn` handler), lines 1522–1568 | Direct port, becomes a `SpatialQueries` return field |
| 3b | Uphill/downhill classification | downhillVector = −(groundNormal × (groundNormal × up)), normalized; classify as uphill when movementDirection · downhillVector is sufficiently negative | same | Direct port |
| 3c | Slope amplification | amplification = maxAmplification × clamp(angle / maxAmplificationAngle, 0, 1), applied only when downhill and angle exceeds a small threshold | same | Direct port, constants named |
| 4 | Wall detection | two forward raycasts (low + high from root position) must both hit, a floor raycast must miss, and the hit normal's dot with world-up must stay below a low threshold (~0.25) to reject slopes/ceilings | `CheckWall`, lines 1054–1083 | Becomes a pure `SpatialQueries` function, shared client/server |
| 5 | Ledge detection | same low forward raycast must hit, but the *high* forward raycast must miss ("wall at your feet, open air above") | `CheckLedge`, lines 1085–1108 | Same, pure function |
| 5a | Climb-jump exit impulse | velocity.Y = fixed upward force over a short fixed duration, facing reset via orientation constraint | `ClimbJump`, lines 1186–1227 | Direct port via `SetVelocityOverride`/`SetOrientationOverride` |
| 6 | Vault height tiering | probe rays at increasing forward offsets pick one of several discrete landing heights above current position | `GetYLevel`, lines 1246–1262 | Replace the 3-tier magic-number lookup with one graduated probe (interpolated height from a single longer ray) rather than porting the tier table |
| 6a | Vault momentum inheritance | launchVelocity = facingDirection × horizontalLaunchForce + up × verticalLaunchForce, **plus** (priorVelocity × 0.4) horizontally and (abs(priorVelocity.Y) / 3) vertically | `ClimbVault`, lines 1264–1337 | Direct port, `0.4`/`3` become named constants |
| 6b | Vault windup snap | position/orientation lerp to a computed landing point over a very short fixed duration before the launch impulse fires | `ClimbVault`, lines 1264–1337 | Via `SetPositionHold`/`SetOrientationOverride` instead of raw `BodyPosition`/`BodyGyro` with hand-tuned P/D |

**Not ported — flag if you want them reconsidered:**
- **Landing/falling animation (Phase 0, §8)** — the reference references a
  `Land` animation track (used as a gate check in `SprintAnimation`, e.g.
  not playing the sprint clip while it's active) but the file doesn't define
  what decides *when* to play it, or a `Jump`/`Fall` split at all. Original
  design, not an extraction.
- **`Skydive`** (lines 927–985) — a fall/dive mechanic tied to a `workspace.Mission` check, reads as very game-specific to the reference project, not obviously part of the Qinggong traversal set.
- **`Health`-scaled force multipliers** — the reference multiplies many launch/impulse forces by a `GetHealth()` fraction (weaker moves at low HP). This is actually thematically interesting for a wuxia game tied to your `Qi`/posture system, but it's a real design decision, not a math port — worth its own discussion once the base moves are in, not bundled into Phase 1–5.

---

## 10. Risk Register

- **`enforceSpeedSanity` exemption window (§7.4)** must ship *with* Phase 1,
  not after — otherwise the first working DoubleJump immediately rubber-bands
  and looks like a regression, not a missing feature.
- **Qinggong resource backing** is still an open decision (§0). Nothing below
  Phase 1 blocks on it — `context.qinggong` can default to "always available"
  until the resource system exists — but resolve it before tuning costs per
  move.
- **`SlideState`/`SlideJumpState` rewrite touches code that's "done but not
  yet playtested"** per `MOVEMENT.md`'s own implementation-status table —
  worth a deliberate playtest pass on current Phase 1 Slide feel *before*
  Phase 3 replaces its internals, so you have a baseline to compare against.
- **Resimulation cost** is real — full trajectory replay for five states is
  the most expensive option on the table (that's what you picked). Watch
  server frame time once WallRun/Vault land; the cost-control throttle in
  §7.3 is load-bearing, not optional.

---

## 11. Optimization Standards (consolidated)

Memory, network, and raw Luau performance are addressed individually above;
gathered here in one place for reference.

**Memory management:**
- Every new backing constraint (`LinearVelocity`/`AlignOrientation`/
  `AlignPosition`) is created once per character life in `CharacterMover.new`,
  Trove-owned, and left parented-but-inert between uses (§2) — zero
  per-move `Instance.new`/`Destroy` churn, unlike the reference's per-dash
  `BodyVelocity` instances.
- `SpatialQueries`/`TraversalMath` are pure functions with no stored state of
  their own — nothing there needs a `Trove` or a cleanup path.

**Network overhead:**
- `TraversalInput` is `Unreliable` (§6) — a dropped input-stream packet just
  means one interpolated frame, never a desynced FSM, since the reliable
  `ClaimTraversalMove`/`RequestMovementTransition` events are what actually
  change state.
- Resimulation only runs for sessions actively claimed into one of the five
  new states (§7.3) — no blanket per-Heartbeat cost added to idle players.
- Every new claim/input event gets its own `RateLimiter` entry, independent
  of the Qinggong resource gate (§6) — same orthogonal-cooldown principle
  `ARCHITECTURE.md` §5/§10 already requires for Run/Sprint.

**Luau performance (the new hot paths specifically):**
- `SlideGroundRaycastThrottleSeconds` throttles Slide's ground raycast via a
  delta-time accumulator (§5) — `ARCHITECTURE.md` §6 explicitly forbids a raw
  raycast on every `RenderStepped`, which is exactly what the reference does.
- `SpatialQueries`/`TraversalMath` functions take and return plain
  `Vector3`/`CFrame`/numbers, never allocate intermediate tables per call —
  matters here specifically because these run every frame during a claimed
  move on both client prediction *and* server resimulation, twice the call
  volume of a normal per-frame function in this codebase.
- `--!strict` typing and `os.clock()`-based timing apply to every new module
  the same as the rest of the codebase (`ARCHITECTURE.md` §6/§7) — not
  restated per-module above, just confirmed as unchanged.

---

## 12. On Attaching the Reference Controller to an AI Assistant

You asked whether to also feed the full `MovementController.luau` alongside
this roadmap to whatever AI helps implement it. Short answer: **keep them
separate, and lean on this doc as the primary spec.**

Reasoning: every formula that matters is already extracted into §9 with line
citations, generalized into math rather than code — that's the point of this
document. Attaching the original 1630-line file on top mostly adds two risks:
it's tempting for an AI (or you, skimming) to fall back on transcribing its
`BodyVelocity`/`BodyPosition`/tween-heavy patterns wholesale instead of the
`LinearVelocity`/`AlignOrientation`/`dt`-integrated approach this roadmap
specifies, and it's a large chunk of someone else's game's source sitting in
a context window for a task that doesn't need it.

If an implementer genuinely needs to double-check an edge case this doc
under-specifies (e.g., exact climb-detach conditions, the uppercut-align
interaction), the line citations in §9 tell you exactly which function to go
re-read in the original file rather than needing it pre-loaded — pull it up
then, not by default.
