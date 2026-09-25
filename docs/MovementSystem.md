# Movement System

How movement works in Jianghu: every state, the controls, the physics, how the server validates it, and the decisions and measurements behind the numbers. This is the one movement document. It replaces `MOVEMENT.md`, `TRAVERSAL-ROADMAP.md`, `Wall Run & Leap Mechanic Guideline.md`, `WallClimbingPlan.md` and `JIANGHU_MOVEMENT_AUDIT.md` (all in git history before 2026-09-24).

Code comments cite this file as `docs/MovementSystem.md §N`. Audit IDs in comments (`audit M-004`, `re-audit N-002`) are listed in [Appendix A](#appendix-a-audit-finding-index). The project-wide rules this system follows are in [`ARCHITECTURE.md`](ARCHITECTURE.md), cited as `ARCHITECTURE §N`.

**Keep it current.** When behavior, a decision or a measured number changes, update the section here in the same change.

---

## 1. Overview

- **16 states.** Ground: `Idle`, `Walk`, `Run`, `Sprint`, `CrouchIdle`, `CrouchWalk`, `Slide`, `HardLanding`. Air: `Airborne`, `SlideJump`, `DoubleJump`. Wall: `WallRun`, `WallLeap`, `WallCling`, `WallBoost`, `Vault`. Ladders and swimming use the Humanoid's own states.
- **Feel:** fast and fluid, momentum-preserving, generous air control. Speed tiers are the "Fast & fluid" preset chosen 2026-09-13 (Walk 18, Run 28, Sprint 40, JumpPower 55), tuned since in playtests.
- **Camera:** strafe-style while the camera is locked (Shift Lock or first-person): you face where the camera looks, and Walk picks one of 8 directional animations from input relative to facing. Unlocked, the character turns to face its movement like default Roblox.
- **Devices:** keyboard only for now (designer decision). Non-keyboard players still must not desync from the server.
- **Trust model:** the client predicts every move immediately; the server mirrors the FSM independently and corrects position when the client's motion isn't something the mirrored state allows (ARCHITECTURE §3, §9).
- **Not built:** Dash, a Qinggong/stamina resource, combat interaction (§14).

---

## 2. Code structure

### FSM engine

`Shared/FSM/StateMachine.luau`, one generic engine used by client and server:

```luau
StateMachine.new(initial, transitions, rules)
fsm:RequestTransition(next, context) -> boolean -- rejects next == current, then checks topology AND rules[next](context)
fsm:CanTransition(next, context) -> boolean      -- same checks, no side effect
fsm.changed                                      -- LemonSignal (next, previous)
```

`transitions` is topology (which states can reach which); `rules` is the `CanEnter` predicate (is it legal right now). Both come from `Shared/Movement/StateRules.luau`, so client and server build identical machines. The FSM holds no movement logic.

`fsm.changed` fires synchronously (LemonSignal `task.spawn` runs to the first yield), so a state's `Enter` can request the next transition in the same call. `SlideJump` and `WallLeap` use this to hand straight to `Airborne` in one tick.

### State contract

Each client state module (`Client/Controllers/Movement/States/*.luau`) exposes `CanEnter` (aliased from `StateRules`, never redeclared), `Enter`, `Update(dt)`, `Exit` and `Reset()` (clears module-scope state at the start of each life). States never require each other; they talk through the context.

### Modules

| Path | Role |
|---|---|
| `Shared/FSM/MovementStates.luau` | State `Symbol`s |
| `Shared/FSM/MovementStateGroups.luau`, `MovementStateNames.luau`, `WallClingExitReasons.luau` | Grounded set, debug names, cling exit reasons |
| `Shared/Movement/StateRules.luau` | Topology + `CanEnter` predicates |
| `Shared/Movement/LandingResolution.luau` | Which state a landing resolves to (shared; require-time assert that every landing caller has an edge to every target) |
| `Shared/Movement/TraversalMath.luau` | Pure math: launch vectors, slope amplification, bounds (`BallisticRise`, `DoubleJumpMaxRise`, `WallLeapMaxHorizontalSpeed`, `DescentCeiling`, ...) |
| `Shared/Movement/SpatialQueries.luau` | Pure geometry reads: ground, support, wall run, cling wall, ledge, climbable, water, floor-below |
| `Shared/Movement/MovementTuning.luau` | Live-tunable subset, ranges, override merge |
| `Shared/Movement/CollisionGroups.luau` | Collision groups per state |
| `Shared/Constants/MovementConstants.luau` | Every movement number (§11) |
| `Shared/Types/MovementTypes.luau` | `MovementContext` and friends |
| `Shared/Util/RateLimiter.luau`, `ViolationTracker.luau` | Remote rate limits; bounded violation history |
| `Client/Controllers/Movement/init.luau` | Per-life orchestrator: FSM, trove, input wiring, context, claims |
| `Client/Controllers/Movement/Core/InputController.luau` | Keys to intents (double-tap, crouch toggle, jump edge, boost) |
| `Client/Controllers/Movement/Core/CharacterMover.luau` | The only thing that touches the Humanoid/root part |
| `Client/Controllers/Movement/Core/ClientMovementContext.luau` | The client's `MovementContext` (adds client-only accessors) |
| `Client/Controllers/Movement/Presentation/FacingController.luau`, `LocomotionAnimator.luau` | Facing and animation; read the FSM, never write it |
| `Client/Controllers/Movement/DevTools/NoclipController.luau`; `Client/State/DebugSnapshot.luau`; `Client/Controllers/DebugOverlayController.luau` | Dev tools (§10) |
| `Client/State/TuningSnapshot.luau` | This session's effective tuning, as last sent by the server (§10) |
| `Server/Services/MovementValidationService/` | Server mirror and every enforcement check (§8); `init.luau` owns sessions and the Heartbeat order, one module per check (see §8) |
| `Server/Services/MovementTuningService.luau`, `DevToolsService.luau` | Live tuning; teleport/noclip/overlay remotes |
| `Server/State/*.luau` | Per-player tuning overrides, noclip, overlay-open records |
| `Server/Events/*.luau` | Server-to-server signals: `CharacterTeleported`, `VerticalAllowanceGranted`, `MovementViolation` |
| `Assets/Animations/Movement.model.json`, `Assets/UI/MovementDebugOverlay.model.json` | Animation instances; the F4 overlay (Studio-authored instance trees) |

`Loader.LoadChildren` only requires direct children of `Controllers`/`Services`, so a system with private helper modules uses Rojo's `init.luau` folder convention (`Movement/`).

### Context

`MovementContext` (`Shared/Types/MovementTypes.luau`) is what every `CanEnter` reads: `grounded`, `jumping`, `moveIntent`, `crouchHeld`, `runDuration`, `doubleJumpUsed`, `fallHeight`, `preAirborneLocomotion`, `cameraLocked`, wall queries, lockouts, `constants` (this session's effective tuning), etc. The client builds it from its own input and physics; the server builds its own copy from replicated state and its own probes (§8.1). The client's `fsm.changed` handler builds **one** context and passes it to both `Exit` and `Enter` (a second build would read state the `Exit` just cleared).

### Performance rules

`os.clock()` only. Every per-life/per-session object owns a `Trove`, destroyed once. Raycasts are throttled with dt/`os.clock()` accumulators, never per frame. Shared `RaycastParams` are reused (never one per cast). Effective tuning tables are cached and frozen. No blanket per-Heartbeat network traffic: the debug broadcast only runs while the overlay is open.

---

## 3. Controls and triggers

| Input | Effect |
|---|---|
| WASD | Move. Camera-relative `MoveIntent` (forward/backward/strafe flags + direction) |
| W double-tap within `RunDoubleTapWindowSeconds` (0.3 s) | `Run` (from Idle/Walk, grounded) |
| Stay in `Run` for `SprintThresholdSeconds` (3 s) | `Sprint`, self-triggered by `RunState` (there is no sprint key) |
| Left Ctrl | **Toggles** crouch (press on, press again off; release does nothing). Crouch from Idle/Walk, `Slide` from Run/Sprint |
| Space, grounded | Humanoid jump (`JumpPower`); from `Slide` it's a `SlideJump` |
| Space, airborne | In order: `WallLeap` (if wall-running), else `WallRun`, else `Vault`, else `WallCling`, else `DoubleJump`. The first legal one wins, so a nearby wall never consumes the double jump |
| Space, clinging | `Vault`, if a ledge is in reach; nothing otherwise |
| (automatic) during `WallBoost` | `Vault` as soon as the lip comes into range, no press needed |
| F | `WallBoost` while clinging, once the cling has lasted `WallBoostMinClingSeconds` (0.6 s); once per cling |
| S (pull away from the wall) | Drop from `WallCling` |
| F4 | Debug overlay (developers only, §10) |

Space is an edge from `InputController` (`_jumpHeld` latch), not `UserInputService.JumpRequest`, which refires after takeoff (engine quirk). Held keys are released on `WindowFocusReleased`/`TextBoxFocused`, and input state resets each life.

Rules worth knowing:
- **Sprint drops** back to Run on backpedal or pure strafe (forward-diagonal is fine), to Idle when all input stops. A jump or stop resets the Run dwell clock; it doesn't pause it.
- **Landing never grants Run from held W** (Run needs the double-tap). Exception: `preAirborneLocomotion`. If you left the ground in Run/Sprint and land still moving forward, you land back in that tier.
- **Can't jump while crouched** (the jump input is sunk via `ContextActionService`); walking off a ledge while crouched still falls.

---

## 4. States

### 4.1 Ground ladder: Idle, Walk, Run, Sprint

Driven by `Humanoid.WalkSpeed` per tier (Walk 18, Run 28, Sprint 40) and the default Roblox control scripts; states only set the tier and read grounded. Idle/Walk follow move input; Run is claimed (double-tap); Sprint is earned by dwell. Sprint's forward check is `SprintForwardDeadzone` (0.5): real WASD only makes 0°/45°/90°+ angles, so any threshold between cos 45° and 0 admits every real diagonal and rejects a spoofed near-sideways `MoveDirection`.

### 4.2 Crouch and slide

- **CrouchIdle / CrouchWalk:** `CrouchSpeed` (9). CrouchWalk is always reached through CrouchIdle (landings and Idle/Walk go to CrouchIdle first; move input moves on the next tick).
- **Slide** (Ctrl from Run/Sprint): a committed move. Entry speed = real horizontal speed, capped at `SprintSpeed`, times `SlideEntrySpeedMultiplier` (1.25), so at most 50. It then decays linearly at `SlideDecayRate` (20/s) until `CrouchSpeed`, then ends in CrouchWalk/CrouchIdle. Toggling crouch off mid-slide doesn't cancel it. Linear decay gives a fixed duration, `(entry - CrouchSpeed) / SlideDecayRate`, that level design can reason about.
  - Driven by a horizontal-only `LinearVelocity`; `WalkSpeed` is 0 during the slide so the Humanoid doesn't fight it.
  - **Steerable:** the direction follows facing every tick (camera when locked, move direction when unlocked). No turn-rate cap.
  - **Slope amplification:** going downhill on slopes between `SlideSlopeAngleThresholdDegrees` (5°) and `SlideMaxWalkableSlopeDegrees` (8°) adds up to `SlideSlopeAmplificationCap` (12) on top of the decaying speed. It's added to the output only, never fed back into the decay, so slide duration doesn't change with terrain. Ground normal comes from a throttled `QueryGround` (0.1 s).
- **SlideJump** (Space during Slide): one-tick state. Horizontal = slide direction × min(slide speed + `SlideJumpBoostAmount` (50), 50). Vertical = `SlideJumpUpwardSpeed` (63, about 10 studs of rise vs 7.7 for a normal jump). Both are set explicitly, then it hands to Airborne. Crouch auto-re-entry is suppressed after a slide jump until Ctrl is released.
  - The explicit 63 exists because slides used to launch at 62-64 st/s as a side effect. The designer kept that height on purpose (§9).

### 4.3 In the air: Airborne, DoubleJump

- **Airborne:** no speed of its own; horizontal speed carries from takeoff, with the Humanoid's air control toward `WalkSpeed`. Every move that ends mid-air routes back through Airborne. Rising plays `Jump`, falling plays `Fall`.
- **DoubleJump** (Space in the air, once per airborne stretch, reset on landing; the server also resets it on the first real touchdown after the double jump, because a quick hop can land and take off without its mirror ever seeing both the grounded label and the ground at once): a vertical-only `LinearVelocity` that starts at `DoubleJumpForce` (50) and decays to half (`DoubleJumpDecayFloorFraction`) over `DoubleJumpDecayDurationSeconds` (0.45 s), then releases into a ballistic arc. Horizontal is untouched. Landing mid-impulse resolves straight to the landing target.

### 4.4 Landing

`LandingResolution.Resolve` (shared) picks the target:
1. Fall height (peak since leaving the ground minus current height) ≥ `HardLandingHeightThreshold` (120 studs): **HardLanding**.
2. Crouch on: CrouchIdle/CrouchWalk.
3. Moving forward with `preAirborneLocomotion` set: back into Run/Sprint. A vault clears it, so it never resumes after one (§4.8).
4. Otherwise Walk or Idle.

- **Medium landing** (client-only feel): fall height ≥ `MediumLandingHeightThreshold` (60) lands normally but with `WalkSpeed` × 0.7 for 0.55 s.
- **HardLanding:** `WalkSpeed` 0 and jump blocked for `HardLandingDurationSeconds` (1.11 s, the clip length). Ends early only if the floor disappears. **Server-enforced** (§8.5).
- Fall height survives Airborne↔DoubleJump/WallRun/WallLeap/WallCling/WallBoost/Vault hops, so a cling partway down a long fall doesn't erase it. Swimming resets it.

### 4.5 WallRun and WallLeap

**Enter WallRun:** Space while airborne, when all of these hold:
- A side wall is found by `SpatialQueries.QueryWallRun`: a spherecast (radius 1.5, up to 6 studs) along the root's RightVector and its mirror, nearer hit wins. Its normal must be near-horizontal (|normal.Y| ≤ `WallDetectMaxUpDot` 0.3).
- It isn't the wall you just leapt from (no WallLeap chains; cleared on landing).
- Horizontal speed ≥ `WallRunMinEntrySpeed` (10).
- Move input lines up with the wall's tangent (dot ≥ `WallRunEntryDotThreshold` 0.5).
- You're **facing** along it too (same threshold). Backpedalling or strafing along a wall in Shift Lock doesn't start a wall run.

**While running:**
- A full-force `LinearVelocity` holds you on the tangent at `WallRunSpeed` (35), sinking at `WallRunSinkSpeed` (6).
- You're kept `WallRunClingDistance` (2) off the wall by a correction term (rate 8, capped at 20 st/s), with a one-time position snap at entry.
- The tangent and the Left/Right animation are locked at entry; facing is locked along the tangent.

**Ends:**
- Landing.
- Losing the wall.
- The live normal turning more than `WallRunMaxNormalDeviationDegrees` (35°) from the entry normal (corners snap off, no re-steering).
- `WallRunMaxDurationSeconds` (3 s).
- Space → **WallLeap**.

**WallLeap:** one tick. Launch = current velocity direction × (speed + `WallLeapBurstForce` 75) + wall normal × `WallLeapPushForce` (75), vertical `WallLeapUpwardForce` (100). Then Airborne. The fastest possible horizontal launch is derived exactly from constants (`WallLeapMaxHorizontalSpeed`, about 166 at current tuning), and the server allows that for the flight (§8.2).

### 4.6 WallCling and WallBoost

Designer decisions for this mechanic:

| Topic | Decision |
|---|---|
| Shape | Static cling, then F for one upward boost. No steered climbing |
| Entry | Airborne, Space, facing the wall head-on (within `WallClingMaxFacingAngleDegrees`, 35°) |
| Surfaces | Any near-vertical (|normal.Y| ≤ 0.26), collidable, **anchored** wall; no tag needed |
| Hold | Zero velocity (full-force override, cancels gravity); Space vaults if a ledge is in reach (§4.8), otherwise does nothing |
| Limit | Hard time cap `WallClingMaxDuration` (2.5 s); no resource cost |
| Drop | S (pull away past `WallClingDropInputThreshold` 0.5): falls with a 10 st/s push off the wall |
| Boost | F, after clinging at least `WallBoostMinClingSeconds` (0.6 s; earlier presses do nothing): instant `WallBoostUpwardForce` (120, about 36.7 studs of rise) plus `WallBoostSeparationSpeed` (12) away. Free, once per cling |
| Re-cling | Allowed after a lockout: timeout 0.75 s, drop 0.3 s, post-boost 0.25 s (all server-owned) |
| vs WallRun | Separated by angle: head-on is cling, side-on is wall run |
| vs WallLeap | Can't cling to (or wall-run on) the wall you just leapt from until you land. The server also clears it on its first real touchdown after the leap, since on a quick hop its mirror can miss the landing (fixed 2026-09-25) |
| vs DoubleJump | A valid cling wins and doesn't spend the double jump |

- **Detection:** `SpatialQueries.castClingWall`, a forward Blockcast (2×4×0.2, body height, 3 studs). The facing check lives in `CanEnter[WallCling]`, so the angle can be tuned live.
- **Boost:** the `WallBoost` state lasts `WallBoostStateDuration` (0.6 s), then Airborne.
- **Climbing a tall wall:** infinite by design (re-cling plus a free boost). Possible limiters are parked in §14.

### 4.7 Ladders and swimming

Humanoid `Climbing` and `Swimming`, no custom states. The server accepts climbing only on a `TrussPart` or on geometry tagged `MovementConstants.ClimbableTag` (`"Climbable"`, on the part or any ancestor). **Level authors must tag non-truss ladders**, or climbing them gets corrected. Swimming counts only in real terrain water, and it resets fall height.

### 4.8 Vault

A mantle assist, not a climb: when a jump comes up just short and the lip is around your chest or head, Space puts you on top. Tall walls are WallCling's job. The Sorcery reference and the reasoning behind every difference from it are in [`VaultMechanic.md`](VaultMechanic.md).

**Enter:** Space while airborne (Airborne, DoubleJump) or clinging, or **automatically during WallBoost** (designer, 2026-09-25: cling, boost, and the boost carries you over the lip). Either way `SpatialQueries.QueryLedge` must find a ledge and:
- You're facing it head-on (within `VaultMaxFacingAngleDegrees`, 35°), judged on the direction the probe was cast along.
- `VaultCooldownSeconds` (0.5 s) has passed since the last vault (server-owned).
- Not from WallRun: a ledge ahead is a different wall. Leap off, then vault.

**Automatic during a boost:** the client probes for a ledge while in WallBoost (Space still works too). The boost rises through the 4.5-stud height window in a few hundredths of a second, so the probe isn't on the usual 0.1 s throttle: its interval is `TraversalMath.VaultAutoProbeInterval`, the window over (`WallBoostUpwardForce` × `VaultAutoProbeSamplesPerWindow`), about 0.019 s at shipped tuning (effectively every frame, for the boost's 0.6 s). The server needs nothing new: the claim is the same, and it checks the ledge the same way (§8.4).

**The probe** (`QueryLedge`, from the root's CFrame; heights measured from the feet):
- **Wall:** a ray forward `VaultReach` (3) at `VaultMinLedgeHeight` (1.5, knee height) hits an anchored, collidable, near-vertical face (|normal.Y| ≤ 0.26).
- **Clearance:** the same ray at `VaultMaxLedgeHeight` (6) must miss. The wall ends within reach; a taller one is a cling.
- **Top:** a ray down from `VaultTopInset` (1.25) past the face, from 6 to 1.5, finds the real top. It must be standable (normal.Y ≥ 0.7).
- **Depth:** the same ray `VaultMinTopDepth` (1.5) further in must hit within `VaultTopDepthTolerance` (0.5) of the top, so rails and thin walls fail.
- **Headroom:** the leg footprint swept up `VaultHeadroom` (5) from the top must miss.

**Motion** (one state, two phases; the whole state lasts `VaultDurationSeconds`, 0.32 s, the Vault clip's length):
1. **Mantle** (at most `VaultMantleSeconds`, 0.2 s; shorter when you're already rising faster, so the mantle runs at your own upward speed and a fast boost carries straight over the lip instead of braking): a full-force velocity override carries the root straight up the wall face until the feet are `VaultMantleClearance` (0.5) above the top, then straight across onto it, at one constant speed (`TraversalMath.VaultMantlePoint`; each frame aims for where the path will be at the end of that frame, so it arrives on time). Rising first keeps the body clear of the lip. The rise is the ledge height plus the clearance (up to 6.5 studs); the leg across is at most reach + inset (4.25 studs). Facing is locked into the wall. It replaced a one-frame `PivotTo` snap that read as a teleport (2026-09-25 playtest).
2. **Launch:** when the mantle ends, one-shot velocity writes along the camera's flattened look: `VaultForwardSpeed` (15) forward plus `VaultHorizontalMomentumKeep` (40%) of the entry horizontal velocity, and `VaultUpwardSpeed` (35) plus |vy| × `VaultVerticalMomentumKeep` (1/3) up, the fall-speed part capped at `VaultMaxMomentumUpward` (20). At most 55 up, the same as a jump.
3. **Window:** the rest of `VaultDurationSeconds`, then Airborne, which lands on the ledge (a 35 up launch comes back down in about 0.36 s). Landing isn't checked at all until the window ends: the feet pass just above the ledge, and a mid-vault read used to resolve a landing (often a resumed Run) instead of handing to Airborne (2026-09-25 playtest). Jump is blocked for the whole state, so the Space press can't also fire a Humanoid jump.

**Never into Run/Sprint:** entering Vault clears `preAirborneLocomotion` on both sides, so neither the vault nor the landing after it resumes Run/Sprint (`LandingResolution.Resolve(context, false)` for Vault's own landing). Vault has no Run/Sprint edges, so a double-tap W mid-vault can't start Run either. You land on the ledge walking.

**After a vault:** the double jump isn't spent, but DoubleJump is blocked for `VaultDoubleJumpBlockSeconds` (0.25 s). Facing is locked to the launch direction during the window.

---

## 5. Transition table

Topology from `StateRules.Transitions` (`CanEnter` still has to pass). "Grounded set" = Idle, Walk, Run, Sprint, CrouchIdle, CrouchWalk, HardLanding.

| From | To |
|---|---|
| Idle | Walk, Run, Airborne, CrouchIdle |
| Walk | Idle, Run, Airborne, CrouchIdle |
| Run | Idle, Walk, Sprint, Airborne, Slide |
| Sprint | Idle, Run, Airborne, Slide |
| CrouchIdle | Idle, Walk, CrouchWalk, Airborne |
| CrouchWalk | Idle, Walk, CrouchIdle, Airborne |
| Slide | CrouchIdle, CrouchWalk, SlideJump, Airborne |
| SlideJump | Airborne |
| Airborne | Grounded set, DoubleJump, WallRun, WallCling, Vault |
| DoubleJump | Airborne, grounded set, Vault |
| HardLanding | Grounded set (minus itself), Airborne |
| WallRun | Airborne, grounded set, WallLeap |
| WallLeap | Airborne |
| WallCling | Airborne, WallBoost, grounded set, Vault |
| WallBoost | Airborne, grounded set, Vault |
| Vault | Airborne, Idle, Walk, CrouchIdle, CrouchWalk, HardLanding (no Run/Sprint, §4.8) |

Every state that can land has an edge to every state `LandingResolution.Resolve` can return for it (Vault resolves without resuming Run/Sprint); a require-time assert enforces it (a missing edge once stranded both sides in WallRun/WallCling after landing).

---

## 6. Physics, facing, animation and collision

- **Speed tiers** are `Humanoid.WalkSpeed`; `UseJumpPower = true` with `JumpPower` from tuning. A medium-landing slow is a timed multiplier re-applied every Heartbeat.
- **`CharacterMover`** is the only code that touches the Humanoid/root part:
  - `SetVelocityOverride(velocity, maxForce?)`/`ClearVelocityOverride` drive one `LinearVelocity`, created once per life and left inert between uses (world-relative, `ForceLimitMode = PerAxis`). Per-axis force lets DoubleJump drive only Y and Slide only X/Z.
  - `SetHorizontalVelocity`/`SetVerticalVelocity` are one-shot writes for launches that hand off in the same tick (SlideJump, WallLeap, WallBoost, Vault, cling drop). A constraint there would never get its `Exit` to clear it.
- **Facing:** `FacingController` flips `Humanoid.AutoRotate` every frame: off plus face-the-camera while `MouseBehavior == LockCenter` (Shift Lock/first-person), on otherwise. States can set a lock direction (WallRun faces along the tangent); zero vectors mean "no lock".
- **Animation:** `LocomotionAnimator` destroys the default `Animate` script, loads the clips from `Assets/Animations/Movement.model.json` (a blank `AnimationId` is skipped, not an error) and crossfades on state changes (`AnimationFadeTimeSeconds`).
  - Walk has 8 directional clips when the camera is locked. Unlocked it always plays Forward, which avoids stutter while `AutoRotate` swings.
  - Airborne plays Jump/Fall from the Humanoid state. Landing overlays `Land` for `LandingAnimationHoldSeconds`; HardLanding plays `LandHard` for its whole state.
  - One-tick states (SlideJump, WallLeap) are shown with a transient hold.
- **Collision groups** (`CollisionGroups.luau`): `Character`, `CharacterCrouched` (CrouchIdle/CrouchWalk/Slide/SlideJump), `CrouchPassable`. Crouched characters don't collide with `CrouchPassable`, so level authors put low bars and vents in it.
  - Applied on both sides from each side's own FSM; parts added later (accessories) join the current group.
  - Player-vs-player collision stays on (designer decision).

---

## 7. Networking

All remotes are in `network.zap` (regenerate with `zap network.zap`); every client→server handler is rate-limited (ARCHITECTURE §5, §10).

| Event | Dir | Payload | Limit |
|---|---|---|---|
| `RequestMovementTransition` | C→S | `Run`, `Sprint` (state claims); `CrouchDown`/`CrouchUp`, `CameraLocked`/`CameraUnlocked` (level claims) | 5/s for Run/Sprint; 6/s shared by level claims |
| `ClaimTraversalMove` | C→S | `DoubleJump`, `WallRun`, `WallLeap`, `WallCling`, `WallBoost`, `Vault` | 5/s |
| `MovementDebugState` | S→C | Mirrored state, run duration, Speed violations (developers, overlay open only) | Unreliable |
| `RequestSetTuning` / `TuningState` | C→S / S→C | One override / the session's effective tuning list | 5/s, dev-only |
| `RequestSetNoclip` / `NoclipState` | C→S / S→C | Noclip on/off | 2/s, dev-only |
| `RequestDevTeleport` | C→S | Position (NaN/inf rejected) | 3/s, dev-only |
| `RequestSetDebugOverlayOpen` | C→S | Overlay open | 5/s, dev-only |

- **What needs a claim.** Only things the server can't see: Run (double-tap), Sprint (dwell), crouch and camera-lock *levels* (no replicated equivalent), and the traversal moves. Idle/Walk/Airborne/landings/slide/slide jump are mirrored passively from replicated Humanoid state, `MoveDirection` and server probes.
- **Levels, not edges:** crouch and camera lock are sent on every change **and** resent every 1 s (`CLAIM_RESYNC_INTERVAL_SECONDS`), as are Run/Sprint while held. A dropped packet heals within a second. Crouch is sent even mid-air, so a crouched landing is decided correctly.
- **No rejection messages:** the server never tells the client "no". Exits are inferred on both sides from the same geometry and timers.

---

## 8. Server validation

`Server/Services/MovementValidationService/`, one `PlayerSession` per character life (own `Trove`, destroyed on death, removal, respawn or leave). The Heartbeat order matters and is documented at the loop in `init.luau`: support probe → root history → fall height → wall probes → passive mirror → buffered claim retries → slide ground → speed check → vertical ceiling → debug broadcast.

| Module | Role |
|---|---|
| `init.luau` | Session create/destroy, player lifecycle, remote wiring, the Heartbeat order |
| `Sessions` | The `PlayerSession` record and the live sessions by player |
| `Probes` | Support (ground truth, §8.1), floor-velocity trust, root history, fall height, slide-ground, wall and ledge probes |
| `Context` | Move-intent classification; the server's `MovementContext` |
| `Mirror` | Passive transitions and wall/HardLanding force-exits (§8.1, §8.4, §8.5) |
| `TransitionBookkeeping` | Per-transition session bookkeeping; fires `MirrorStateChanged` |
| `SpeedCaps` / `SpeedCheck` | Per-state caps and allowances / the windowed budget and corrections (§8.2) |
| `VerticalCeiling` | Anchor, raise, descent and correction; `VerticalAllowanceGranted` grants (§8.3) |
| `ClaimTiming` | Claim lag, buffer wait, latency credit (§8.2-§8.4) |
| `TraversalClaims` / `TransitionClaims` | `ClaimTraversalMove` / `RequestMovementTransition` and their claim buffers (§8.4, §8.1) |
| `Violations` | Violation trackers and `MovementViolation` (§8.7) |
| `DebugBroadcast`, `DebugFlags` | The F4 overlay broadcast; every capture/logging switch (§10) |

### 8.1 Mirror and "grounded"

- **The mirror** is built from the same `StateRules`. Passive transitions (Idle/Walk/Airborne, landings, slide decay, crouch states, Sprint→Run demotion) are decided by the server itself every Heartbeat. Claims are checked with the same `CanEnter`, against the server's own context.
- **Support probe** (`SpatialQueries.QuerySupport`): the R6 leg footprint (2×1, turned with the rig's yaw) swept 4 studs down from the root, collidable non-water geometry only. It's the server's ground truth.
- **Grounded for the mirror** (`Probes.IsGrounded`) = support **and** a grounded Humanoid label, or support that has lasted a full 0.5 s window while labelled airborne. A client can't fake a landing mid-air (DoubleJump refresh, fall height) or claim to be airborne while standing to keep air caps.
- **Intent:** `classifyMoveIntent` rebuilds forward/backward/strafe from `rootPart.CFrame` vs `MoveDirection`. Both are client-written, so they only choose mirror tiers; every tier they unlock is still enforced against real displacement.
- **Sprint:** the server times Run itself, backdated by half the measured ping (capped at half the threshold). A Sprint claim that lands milliseconds short of the dwell is buffered and retried. Backpedal demotion only runs while the camera is locked (from the `CameraLocked` level claim), because unlocked, facing deliberately lags movement.

### 8.2 Horizontal speed budget

- **Budget:** every Heartbeat adds `(effective cap + trusted floor speed) × dt`. Every 0.5 s (`SpeedCheckIntervalSeconds`) the real X/Z displacement is compared with budget × `SpeedToleranceMultiplier` (1.3, unmeasured, §9).
  - Transitions never reset the window, so it's judged against exactly the caps that were live, and a client toggling states can't discard evidence.
  - Over budget: snap X/Z back to the window start and zero horizontal velocity.
- **Caps by state:**

| State | Cap |
|---|---|
| Idle, Walk | 18 |
| Run | 28 |
| Sprint, Airborne, DoubleJump, WallLeap, WallBoost, Vault | 40 |
| CrouchIdle, CrouchWalk | 9 |
| Slide, SlideJump | 50 + slope amplification |
| WallRun | 35 |
| WallCling | 0 |
| HardLanding | 6 (unmeasured) |

- **Airborne allowance** (`airborneAllowedSpeed`): WallLeap (the exact bound, about 166) and SlideJump (50) raise the air cap for the whole flight, since nothing slows horizontal flight. A Vault raises it only if `VaultMaxHorizontalSpeed` (15 plus 40% of the cap in force before it) is above the cap, which it isn't at shipped tuning.
  - Ends on landing, entering WallRun/WallCling, a verified ladder, water, or a vertical correction.
  - The first real support after the launch's apex starts a 1 s expiry, so a client that never reports landing can't hop along the ground keeping it.
- **Landing-momentum grace:** after a transition that lowers the cap, the previous cap (allowances included) applies for `LANDING_MOMENTUM_GRACE_SECONDS` (1 s, measured, §9). It doesn't apply to HardLanding.
- **Displacement credit:** the vault mantle's leg across moves the root up to `VaultReach` + `VaultTopInset` (4.25) studs sideways in a fraction of its 0.2 s, faster than the cap. An accepted Vault allows exactly that distance on top of the budget (not scaled by the tolerance) in every window that starts within one claim lag plus one mantle of the accept, since the mantle can replicate on either side of it and a window can roll over in between.
- **Claim latency credit:** when an accepted claim raises the cap, the difference is credited for one network leg (server-measured ping) plus any time the claim waited in a buffer, capped at one window.
- **Floor velocity** (`trustedFloorVelocity`, re-audit N-003):
  - Anchored or grounded assemblies and server-owned parts: full velocity.
  - Another player's character: horizontal only, up to that player's own allowed carry speed.
  - Any other client-owned part: nothing. A client-driven vehicle gives its driver no credit; there are no vehicles yet.

### 8.3 Vertical ceiling

The highest Y the character can legally be at, from server-known impulses only.

- **Anchor:** whenever the support probe finds ground (whatever the label says), or while swimming/noclipping/teleported: ceiling = Y + rise of one jump, apex time = now + launch/g.
  - The jump speed is `JumpPower` + a vouched floor's upward speed. A pending SlideJump uses `SlideJumpUpwardSpeed` until takeoff.
  - The anchor uses support, not the label: the Humanoid label reaches the server ~0.15-0.2 s before the position stream, and label-timed anchors went stale (§9).
- **Raises:** each accepted move adds its maximum rise and moves the apex time: DoubleJump (`DoubleJumpMaxRise`, `DoubleJumpTimeToApex`), WallLeap and WallBoost (ballistic), WallRun entry snap, Vault (`VaultMaxRise`: the mantle's `VaultMaxLedgeHeight` + `VaultMantleClearance` plus the ballistic rise of the fastest launch, with the apex time pushed back by one mantle), `VerticalAllowanceGranted`.
  - The vault mantle ends with the feet just above the ledge, so the support probe re-anchors there before the launch leaves. For one claim lag plus one mantle after an accepted Vault, that anchor allows the vault's fastest launch (`VaultMaxUpwardSpeed`) instead of only a jump. Launches replace vertical velocity, so "old ceiling + rise" is a true bound.
- **Descent:** while unsupported, after the apex time the ceiling falls from rest under gravity (`TraversalMath.DescentCeiling`), so the character can't hover or float down.
  - WallRun/WallCling (server-mirrored, wall-probed, time-limited) and verified climbing hold the apex time at "now".
  - Climbing lets the ceiling rise at no more than the speed cap, never more than one jump above the real position.
- **Ordering:** a claim and the positions it explains arrive separately. `ClaimTiming.ClaimLagSeconds` = one-way ping + `WallRunClaimBufferSeconds`, capped at 0.5 s. The descent curve starts that much late, and an excess must outlast it before it's corrected.
- **Correction:** snap down to the ceiling, never below standing height on the floor underneath (`QueryFloorBelow`), and kill upward velocity. Report `VerticalCeiling`.
- **Tested:** the bounds are simulated against the client's real motion in `tests/specs/TraversalMath.spec.luau` (jump, WallLeap, WallBoost, Vault, DoubleJump at 20-240 fps).

### 8.4 Traversal claims

- **Claims are re-mirrored first:** a claim arrives between Heartbeats, so the handler first refreshes support, the wall probes and the passive mirror from the freshest replicated state, then runs the real `CanEnter`/topology check.
- **Buffering:** a rejected WallRun, WallLeap or WallCling claim is retried every Heartbeat for `WallRunClaimBufferSeconds` (0.25 s, sized from playtests of this exact ordering). It stays alive while the mirror is still in DoubleJump, and is dropped if the mirror goes anywhere else. A pending WallRun or WallCling claim also ends the mirror's DoubleJump on the spot: neither is reachable from DoubleJump, so the client's has already ended, while the server's runs from its own later accept and could outlast the buffer (quick double jump → wall run, fixed 2026-09-25). Ending it early gains nothing: same cap, and its ceiling raise is already applied. A WallBoost claim rejected while the mirror is still clinging is buffered the same way, and so is every rejected DoubleJump: claims lead the position stream like the Humanoid label does, so on a quick hop the DoubleJump arrives before the touchdown that refreshes it. The cling and boost claims share one reliable stream, so the server's cling clock differs from the client's only by jitter, but mashing F lands right on the 0.6 s boundary. The server's cling clock starts at its own accept, backdated by any time the cling claim spent buffered. A raise accepted while the positions still show the ground (the claim arriving before the takeoff) is kept and re-applied by each ground anchor until lift-off, for up to `ClaimTiming.ClaimLagSeconds`.
- **Vault:** the server probes the ledge only at claim time and on buffered retries (a vault has no sustain check). The client's mantle carries its root up and onto the ledge right away, and those positions can reach the server before the claim is judged; from up there no wall is in front of it. So `Probes.UpdateLedgeQuery` tries the current root, then each root CFrame recorded in the last claim lag (`Probes.RecordRootHistory`, every Heartbeat), newest first, and the facing check uses the facing of whichever position found the ledge. A rejected Vault is buffered like DoubleJump while the mirror is in Airborne, DoubleJump, WallCling or WallBoost. The cooldown clock is the accept time, backdated by any time buffered. The launch direction comes from the client's camera and isn't checked; its magnitude is bounded (§8.2, §8.3).
- **Wall states on the server:** the server runs the same probes (throttled at 0.1 s, forced fresh at claim time) and force-exits the mirror when the wall is lost, a corner exceeds the deviation, or the duration cap passes.
  - The server's timers always start at its own accept, so they end no earlier than the client's.
  - WallRun's corner reference is the first probe taken *after* the accept, never the claim-time probe: the replicated rig can still be turned toward the previous face, which at a wall end made every wrap-around wall run force-exit 0.1 s in (fixed 2026-09-25). If that first probe finds no wall, the run ends as lost-wall.
  - Cling lockouts and the post-boost cooldown are server-owned. The drop lockout stays client-only: the server can't tell a drop from a lost wall, and a drop gains no height.

### 8.5 HardLanding

Entered by the mirror's own landing resolution from its own fall height. During the lock only the server's support probe can end it early (the floor vanished → Airborne). Losing support while more than 1 stud above the lock position is a jump-out: `HardLandingEscape`, snap back to the lock position. The lock's last `ClaimTiming.ClaimLagSeconds` is exempt, because the client's lock started when *it* landed and ends first.

### 8.6 Exemptions and hooks

- `Server/Events/CharacterTeleported`: fire after moving a character on purpose. It resets the speed window and re-anchors the ceiling.
- `Server/Events/VerticalAllowanceGranted(player, rise)`: for knockback, launch pads or future Qinggong. Grants a rise from the current position, with the matching apex time.
- Noclip (`Server/State/NoclipState`, server-authorized) exempts the speed and vertical checks.
- External horizontal velocity (knockback, a combat `Overridden` state) has **no** carve-out yet. Whatever adds it first needs its own exemption (§14).

### 8.7 Violations

Every correction goes through `Violations.Report`: recorded per kind (`Speed`, `VerticalCeiling`, `HardLandingEscape`) in a `ViolationTracker`, and fired on `Server/Events/MovementViolation (player, kind, detail, count)`. There is **no kick/flag policy** (designer decision): a future moderation system subscribes. Every correction also zeroes the relevant velocity. In Studio each one prints `[MovementViolation] <player> <kind> state=<mirror> <detail>`.

---

## 9. Tolerances and measurements

ARCHITECTURE §9: a tolerance exists only for a specific, measured, documented cause. Status of every number that isn't a pure design value:

| Value | Status | Cause / evidence |
|---|---|---|
| `LANDING_MOMENTUM_GRACE_SECONDS` = 1 s | Measured 2026-09-14 | 4 captured Airborne→Walk landings: every first check fired at 0.500-0.517 s, none needed a second window |
| `WallRunClaimBufferSeconds` = 0.25 s | Measured 2026-09-19 | Claim-vs-position replication ordering in wall-run/cling playtests; reused wherever the same ordering applies |
| `ClaimTiming.ClaimLagSeconds` (vertical, HardLanding) | Derived | One-way ping (server-measured) + the claim buffer above, capped at one window |
| Claim latency credit | Derived | Cap difference × (one-way ping + buffered time), capped at one window |
| `SlideJumpUpwardSpeed` = 63 | Measured 2026-09-24, then fixed by design | `JUMP_LAUNCH_CAPTURE` on a flat baseplate: Idle jumps 56.0-56.9 st/s, Run 56.6-58.2, SlideJump 61.9-63.7 (JumpPower 55). The slide added about 7 st/s (likely the slide pose pushing off the floor, not confirmed). The designer kept the height; the client now sets 63 explicitly |
| Plain jump launch (56-58 vs `JumpPower` 55) | Measured, no tolerance added | The Humanoid's own jump runs slightly above `JumpPower`; the excess lasts less than the claim-lag window, so nothing is corrected. Revisit if higher-speed jumps start printing violations |
| `SpeedToleranceMultiplier` = 1.3 | **Unmeasured** | Turn on `SPEED_RATIO_CAPTURE`, play honestly with incoming replication lag on, set it to the p99.9 ratio and cite the capture next to the constant |
| `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE` = 6 | **Unmeasured** | Standing-still jitter during the lock; needs the same capture |
| `WallClingSpeedCeiling` = 0 | Design value | The capture's `zeroBudgetDriftMax` is what would justify anything non-zero |
| Stalls longer than one window (audit M-015) | **Unmeasured** | Shows up in the ratio capture's tail |

**Label vs position ordering (measured 2026-09-24):** the replicated Humanoid state label reaches the server about 0.15-0.2 s before the position that shows it. Anything timed off the label (the old ceiling anchor) goes stale. Time things off the support probe or positions instead.

---

## 10. Debug tooling and live tuning

**F4 overlay** (developers only: `DeveloperAllowlist`, which is Studio or an allowlisted `UserId`). It's a Studio-authored instance tree (`Assets/UI/MovementDebugOverlay.model.json`); `DebugOverlayController` only `WaitForChild`s into it. Draggable, three tabs:
- **Movement:** client state, grounded, run duration, velocity; the server's mirrored state with a mismatch flag; state history (10); claim log (8, marked confirmed/unconfirmed when the server state reflects the claim within 2 s); Speed violation history (5).
- **World:** noclip/fly (Space/Ctrl up/down; the server disables collision and exempts validation), teleport by coordinates or click, 8 session-only waypoints.
- **Tuning:** one row per live tunable (current value, input, Set/Clear).

**Live tuning:** `MovementTuning.luau` lists the tunables (56 today) with valid ranges. Overrides are per player, dev-only, bounds-checked server-side, applied to both client feel and server enforcement, and cleared on leave. A live change re-applies the current tier's `WalkSpeed` immediately. Adding a tunable touches `MovementConstants`, `MovementTuning` (name + range), the `TunableConstantName` enum in `network.zap`, and a new `Row_*` in the overlay (built in Studio). Validation tolerances are never tunable.

**Flags** (all `false` in committed code; flip for a playtest, then flip back):

| Flag | File | Prints |
|---|---|---|
| `SPEED_RATIO_CAPTURE` | Validation `DebugFlags` | p50/p99/p99.9/max of displacement ÷ budget every 200 windows, plus `zeroBudgetDriftMax` |
| `VERTICAL_CEILING_DEBUG_LOGGING` | Validation `DebugFlags` | Every frame above the ceiling: y, ceiling, apex, excess, lag |
| `JUMP_LAUNCH_CAPTURE` | Validation `DebugFlags` | Per landing: from-state, peak, time to peak, implied launch speed |
| `SPEED_SANITY_DEBUG_LOGGING` | Validation `DebugFlags` | Cap changes, rate-limited claims, Sprint dwell overshoot, rejected claims |
| `WALL_TRAVERSAL_DEBUG_LOGGING` | Validation `DebugFlags` | Rejected WallRun/WallLeap claims, WallRun force-exits |
| `WALLCLING_DEBUG_LOGGING` | SpatialQueries | Why a cling cast was rejected |
| `WALLRUN_DEBUG_LOGGING`, `WALLCLING_TRACE_LOGGING` | Client `Movement/init.luau` | Client-side wall probe traces |
| `ANIMATION_LOAD_DEBUG_LOGGING` | LocomotionAnimator | Clip loading |

Always on in Studio only: `[MovementViolation]` for every correction, `[TraversalClaim] ... REJECTED` for DoubleJump/WallBoost/Vault claims.

---

## 11. Constants

Everything is in `Shared/Constants/MovementConstants.luau`, with the reasoning next to each value. Groups:

- **Tunable (F4):** speed tiers and jump; Run/Sprint timing; crouch/slide; landing thresholds and durations; DoubleJump; slide slope; WallRun/WallLeap feel; WallCling/WallBoost timings and forces; Vault launch, mantle time, duration, facing, cooldown and double-jump block; animation fade/hold.
- **Structural (not tunable):** cast sizes and reaches (`GroundQueryCastDistance`, `GroundSupportFootprint`, `WallRunSideCast*`, `WallClingDistance`/`CastSize`, `WallDetectMaxUpDot`, `WallClingMaxNormalY`, the `Vault*` ledge geometry: reach, height window, inset, depth, top normal, headroom, mantle clearance), rig facts (`RigRootHeightAboveFeet`, `TerrainVoxelSize`), `DirectionEpsilon`, `ClimbableTag`, `SlideJumpUpwardSpeed`, `WallClingDropSeparationSpeed`.
- **Validation (never tunable):** `SpeedCheckIntervalSeconds`, `SpeedToleranceMultiplier`, `WallRunClaimBufferSeconds`, `WallClingSpeedCeiling`. Network-layer limits (claims per second) live in the services, not here.

A number goes in only once it's a real decision, never as a placeholder. Starting-point values are marked as such in their comments.

---

## 12. Tests

`lune run tests/run` (CI runs it after `wally install`). `tests/harness.luau` maps the Rojo tree onto files so shared modules load unmodified. The specs cover StateRules (topology, CanEnter, WallLeap-chain rule), LandingResolution, StateMachine, MovementTuning (name/range parity) and TraversalMath. That includes simulations proving `DoubleJumpMaxRise`, `DoubleJumpTimeToApex`/`DescentCeiling`, `WallLeapMaxHorizontalSpeed` and the Vault bounds (`VaultMaxRise`, `VaultMaxUpwardSpeed`, `VaultMaxHorizontalSpeed`) bound the client's real motion. `QueryLedge` needs real geometry, so playtests cover it, not specs.

Not covered: the validation service itself (no Lune access to Roblox physics). Its checks are pure arithmetic on the session; extracting them into a shared pure module would let the specs simulate cheaters against them.

Before pushing: `zap network.zap`, `selene src`, `stylua --check src tests --glob '!src/**/Network/network.luau'`, `lune run tests/run`, `rojo build`.

---

## 13. Design decisions

| Decision | Choice |
|---|---|
| Devices | Keyboard only for now |
| HardLanding | Server-enforced |
| WallLeap chains | Not allowed on the same wall until landing |
| Vertical travel | Only the real moves, plus the `VerticalAllowanceGranted` hook for future sources |
| Player collision | On; the speed check credits the floor's velocity |
| Humanoid states | Ladders (truss/tagged) and swimming in scope; other states unhandled |
| Violations | Fire an event only; policy belongs to a future moderation system |
| StreamingEnabled | On (ARCHITECTURE §14); radii still to record |
| Slide jump height | About 10 studs, on purpose (`SlideJumpUpwardSpeed`) |
| Wall run activation | Second Space press in the air, not automatic |
| Wall run corners | Snap off past 35°, no re-steering |
| Wall run lean | From animation clips only (no physics tilt) |
| Vault | A mantle assist: Space at a chest-to-head-high lip, automatic during WallBoost, camera-steered launch, no health scaling (§4.8) |
| Dash | Skipped |
| WallLatch | A separate system, not part of wall run |

---

## 14. Known gaps and future work

**Needs a Studio playtest (with incoming replication lag on):**
- Size `SpeedToleranceMultiplier` and `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE` from `SPEED_RATIO_CAPTURE` (audit M-007, M-015, M-016, M-017).
- Record the `StreamingMinRadius`/`StreamingTargetRadius` values (ARCHITECTURE §14).
- Tag real ladders `Climbable`.

**Needs a playtest (Vault, §4.8):** check the mantle's feel (`VaultMantleSeconds` is live-tunable; much shorter than 0.2 s starts to read as a snap again, though a fast boost already mantles at its own speed); check whether the launch after a fast boost still reads as braking: it caps the upward speed at 55 (`VaultUpwardSpeed` + `VaultMaxMomentumUpward`), and raising `VaultVerticalMomentumKeep`/`VaultMaxMomentumUpward` keeps more of the boost (the server bound follows the same tuning); check that the Humanoid doesn't register the ledge as ground right after the mantle, before the launch lifts off (that would end the vault as a landing); check how high above a cling the automatic boost vault still reaches: `WallBoostSeparationSpeed` (12 st/s) carries you away from the wall, out of the 3-stud reach after roughly 0.15-0.2 s (about 15-18 studs of rise) unless holding W pulls you back. `WallBoostSeparationSpeed` is live-tunable to try 0.

**Residuals (accepted for now):**
- The ceiling's height stacks rises: a DoubleJump on the way down still allows its full rise on top of the old ceiling (at most about one jump over legit play, never unbounded).
- Being knocked upward by another player isn't a server-known impulse.
- A Vault claim delayed past a speed window after its mantle (a resent reliable packet) misses the displacement credit, and that window can correct the mantle.
- CFrame- or tween-driven moving platforms report zero velocity and get no floor credit. So do client-owned platforms and vehicles.
- If crouch and jump are pressed within one network leg, the jump can reach the server before the crouch. The flight is then capped at 40 instead of the slide-jump 50. Not seen in playtests.
- Skimming within about a stud of a surface after a launch's apex, then flying on for over 1 s, loses the airborne allowance.
- A modified client can claim crouch to use the crouched collision group through `CrouchPassable` geometry.
- The camera-locked claim is derived from `not AutoRotate`, which is also false during wall locks. It over-reports; harmless.

**Not built:**
- A spatial "slide under" move, if ever built, shouldn't reuse the `Slide` symbol.
- **Qinggong/stamina** (`context.qinggong` defaults to `math.huge`). Open: is it the same Qi pool combat uses?
- **Combat `Overridden` state:** the one seam combat will use to move the character. It needs a speed-check exemption for external velocity.
- **Combat interaction** (block attacks/parry while clinging, stagger force-exits): no combat FSM exists yet.
- **Wall climbing limiters**, if infinite climbing hurts level design: a chain limit, a cost, a different wall after N boosts. Also a `WallLeap → WallCling` edge, grounded cling, camera changes, climbable-wall hints.
- Gamepad/mobile input.

**Open question:** ARCHITECTURE §7 asks for one-line comments, while the movement code keeps long rationale comments. Undecided.

---

## Appendix A: Audit finding index

The movement audit (2026-09-24, baseline `7b2adab`) and its re-audit of `49c81f0`. Code comments cite these IDs. Status is as of 2026-09-24.

| ID | Finding | Status |
|---|---|---|
| M-001 | Vertical axis unpoliced | Fixed: vertical ceiling (§8.3) |
| M-002 | Transitions reset the speed window, letting a client starve the check | Fixed: per-Heartbeat budget, no resets |
| M-003 | WallLeap allowance came from client velocity and lasted until a spoofable landing | Fixed: exact bound; lifetime via N-001 |
| M-004 | Client-owned Humanoid/physics state treated as ground truth | Fixed: support probe (§8.1) |
| M-005 | WallRun had no HardLanding edge | Fixed + require-time assert |
| M-006 | Dropped `CrouchUp` never repaired | Fixed: crouch as a resent level |
| M-007 | `SpeedToleranceMultiplier` unmeasured | Open: needs capture |
| M-008 | Violations had no consequence beyond a snap | Fixed as an event hook (§8.7) |
| M-009 | Buffered wall claims dropped while mirror in DoubleJump | Fixed |
| M-010 | HardLanding was client-only | Fixed: server-enforced (§8.5) |
| M-011 | No death handling | Fixed (movement side) |
| M-012 | Stuck keys, latched jump, crouch surviving respawn | Fixed |
| M-013 | Keyboard only | Accepted (§13) |
| M-014 | Moving floors/seats treated as speed hacks | Fixed for physics floors; see N-003 |
| M-015 | False positives after long replication stalls | Open: needs capture |
| M-016 | WallCling cap exactly 0 | Open: needs capture |
| M-017 | Other unmeasured tolerances; tunable tolerances | Partly fixed; HardLanding residual open |
| M-018 | Collision groups inert | Fixed: `CrouchPassable` |
| M-019 | Reentrant SlideJump left the wrong collision group | Fixed |
| M-020 | Server read client-local `AutoRotate` | Fixed: camera-lock level claims |
| M-021 | Per-Heartbeat allocations on the server | Fixed |
| M-022 | Module-scope state survived the FSM | Fixed: `Reset()` per life |
| M-023 | Server session lifecycle | Fixed: per-session trove |
| M-024 | WallBoost vertical speed inflated a horizontal cap | Fixed |
| M-025 | Debug prints on in production | Fixed |
| M-026 | Dangling doc references | Fixed: this file |
| M-027 | Stale comments | Fixed |
| M-028 | A tunable touched 8 places | Fixed: 4 files (§10) |
| M-029 | Dev-tool hardening | Fixed (teleport NaN, noclip collision restore) |
| M-030 | Overlay per-frame cost | Fixed |
| M-031 | Magic numbers and style | Fixed |
| M-032 | Tuning change mid-state rubber-banded | Fixed |
| M-033 | `CollisionGroups.Apply` cost | Fixed: cache + watch |
| M-034 | StreamingEnabled undocumented | Documented; radii open |
| M-035 | No tests | Fixed (§12) |
| M-036 | Facing lock direction unguarded | Fixed |
| M-037 | WallLeap chains | Fixed: same-wall rule |
| M-038 | WallCling lockouts client-only | Partly fixed (§8.4) |
| N-001 | WallLeap allowance never expired | Fixed: forced descent + touchdown expiry |
| N-002 | No descent/hover check | Fixed: descent ceiling (§8.3) |
| N-003 | Floor speed trusted any floor | Fixed: `trustedFloorVelocity` |
| N-004 | Climbing worked on any wall | Fixed: truss/tag only |
| N-005 | Support footprint ignored facing | Fixed |
| N-006 | Fix-log drift | Fixed |

---

## Appendix B: Engine pitfalls learned the hard way

- `Loader.LoadChildren` only loads direct children; use a folder with `init.luau` for systems with helpers, or they silently never `Init`.
- Roblox's default `Animate` script fights custom animation on the same `Animator`; `LocomotionAnimator` destroys it (you lose default tool/sit/swim/climb animations).
- `UserInputService.JumpRequest` refires after takeoff; use the Space key edge.
- A second jump press in the air produces no Humanoid state change, so DoubleJump can't be detected from `GetState()`.
- `Cross` operand order: `flatMove:Cross(flatFacing)` gives "positive = right"; the reverse mirrors every lateral bucket.
- `AutoRotate` swings gradually, so facing-relative checks misfire while unlocked (Walk buckets, Sprint demotion).
- A GUI container with a higher `ZIndex` than its children can paint over them once its background turns opaque; keep containers at `ZIndex` 0.
- Shapecasts ignore parts they start inside; pull the sweep's origin back by its radius.
- `CanQuery = false` only takes effect on non-collidable parts, so collidable floors are always found by raycasts.
- The replicated Humanoid state label leads the position stream by ~0.15-0.2 s (§9).
- Humanoid jumps launch slightly above `JumpPower`; a character sliding on a `LinearVelocity` picked up about 7 st/s more (§9).
- A cling wall must be `Anchored`; an unanchored test wall looks like "cling doesn't work".
