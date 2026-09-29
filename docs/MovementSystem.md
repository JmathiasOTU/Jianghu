# Movement System

How movement works in Jianghu: every state, the controls, the physics, how the server validates it, how it looks and sounds, and the decisions and measurements behind the numbers. This is the one movement document. It replaces `MOVEMENT.md`, `TRAVERSAL-ROADMAP.md`, `Wall Run & Leap Mechanic Guideline.md`, `WallClimbingPlan.md` and `JIANGHU_MOVEMENT_AUDIT.md` (in git history before 2026-09-24), and `FLOW.md`, `VaultMechanic.md` and `MOVEMENT_POLISH_ARCHITECTURE.md` (in git history before 2026-09-28; their content is now §4.9, Appendix C and §15). The LedgeJump design slice, `LEDGE_JUMP.md`, is now §4.10.

Code comments cite this file as `docs/MovementSystem.md §N`. Audit IDs in comments (`audit M-004`, `re-audit N-002`) are listed in [Appendix A](#appendix-a-audit-finding-index). The project-wide rules this system follows are in [`ARCHITECTURE.md`](ARCHITECTURE.md), cited as `ARCHITECTURE §N`.

**Keep it current.** When behavior, a decision or a measured number changes, update the section here in the same change.

---

## 1. Overview

- **17 states.** Ground: `Idle`, `Walk`, `Run`, `Sprint`, `CrouchIdle`, `CrouchWalk`, `Slide`, `HardLanding`. Air: `Airborne`, `SlideJump`, `DoubleJump`, `LedgeJump`. Wall: `WallRun`, `WallLeap`, `WallCling`, `WallBoost`, `Vault`. Ladders and swimming use the Humanoid's own states.
- **Feel:** fast and fluid, momentum-preserving, generous air control. Speed tiers are the "Fast & fluid" preset chosen 2026-09-13 (Walk 18, Run 28, Sprint 40, JumpPower 55), tuned since in playtests.
- **Camera:** strafe-style while the camera is locked (Shift Lock or first-person): you face where the camera looks, and Walk picks one of 8 directional animations from input relative to facing. Unlocked, the character turns to face its movement like default Roblox.
- **Devices:** keyboard only for now (designer decision). Non-keyboard players still must not desync from the server.
- **Trust model:** the client predicts every move immediately; the server mirrors the FSM independently and corrects position when the client's motion isn't something the mirrored state allows (ARCHITECTURE §3, §9).
- **Flow:** chaining traversal moves inside a sprint raises the real speed cap, up to 1.5×, then drains (§4.9).
- **Presentation:** sounds, particles, camera FOV/shake and our own shift lock are data-driven off the FSM and never affect gameplay (§15).
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
| `Shared/FSM/MovementStateGroups.luau`, `MovementStateNames.luau`, `WallClingExitReasons.luau` | Grounded set, Flow building/holding sets, debug names, cling exit reasons |
| `Shared/Movement/StateRules.luau` | Topology, `CanEnter` predicates, and where Run/Sprint can be claimed from (`CanClaimFrom`) |
| `Shared/Movement/LandingResolution.luau` | Which state a landing resolves to (shared; require-time assert that every landing caller has an edge to every target) |
| `Shared/Movement/FlowRules.luau` | The Flow sprint chain: when it starts, ends and gains (§4.9) |
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
| `Client/Controllers/FlowBarController.luau`, `Assets/UI/FlowBar.model.json` | Developer-only Flow test meter (§4.9) |
| Presentation modules (`MovementCues`, `SFXController`, `VFXController`, `CameraController`, `MovementCueService`, ...) | Sounds, particles, camera, shift lock (§15.7) |

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
| Space, grounded | Humanoid jump (`JumpPower`); from `Slide` it's a `SlideJump`. From Run/Sprint (or a slide jump) right at a drop-off, it adds a `LedgeJump` burst (§4.10) |
| Space, airborne | In order: `WallLeap` (if wall-running), else `WallRun`, else `Vault`, else `WallCling`, else `DoubleJump`. The first legal one wins, so a nearby wall never consumes the double jump |
| Space, clinging | `Vault`, if a ledge is in reach; nothing otherwise |
| (automatic) during `WallBoost` | `Vault` as soon as the lip comes into range, no press needed |
| F | `WallBoost` while clinging, once the cling has lasted `WallBoostMinClingSeconds` (0.6 s); once per cling |
| S (pull away from the wall) | Drop from `WallCling` |
| F4 | Debug overlay (developers only, §10) |

Space is an edge from `InputController` (`_jumpHeld` latch), not `UserInputService.JumpRequest`, which refires after takeoff (engine quirk). Held keys are released on `WindowFocusReleased`/`TextBoxFocused`, and input state resets each life.

Rules worth knowing:
- **Sprint drops** back to Run on backpedal or pure strafe (forward-diagonal is fine), to Idle when all input stops. A jump or stop resets the Run dwell clock; it doesn't pause it.
- **Landing never grants Run from held W** (Run needs the double-tap). Exception: `preAirborneLocomotion`. If you left the ground in Run/Sprint and land still moving forward, you land back in that tier. A slide jump (or sliding off a ledge) counts as leaving from the tier the slide started in.
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
- **SlideJump** (Space during Slide): one-tick state. Horizontal = slide direction × min(slide speed + `SlideJumpBoostAmount` (50), 50). Vertical = `SlideJumpUpwardSpeed` (63, about 10 studs of rise vs 7.7 for a normal jump). Both are set explicitly, then it hands to Airborne. Crouch auto-re-entry is suppressed after a slide jump until Ctrl is released (the crouch-lock; the server gets it folded into the crouch level, §7). Landing with forward held puts you back in the Run/Sprint tier the slide started from (§4.4).
  - The explicit 63 exists because slides used to launch at 62-64 st/s as a side effect. The designer kept that height on purpose (§9).

### 4.3 In the air: Airborne, DoubleJump

- **Airborne:** no speed of its own; horizontal speed carries from takeoff, with the Humanoid's air control toward `WalkSpeed`. Every move that ends mid-air routes back through Airborne. Rising plays `Jump`, falling plays `Fall`.
- **DoubleJump** (Space in the air, once per airborne stretch, reset on landing; the server also resets it on the first real touchdown after the double jump, because a quick hop can land and take off without its mirror ever seeing both the grounded label and the ground at once): a vertical-only `LinearVelocity` that starts at `DoubleJumpForce` (50) and decays to half (`DoubleJumpDecayFloorFraction`) over `DoubleJumpDecayDurationSeconds` (0.45 s), then releases into a ballistic arc. Horizontal is untouched. Landing mid-impulse resolves straight to the landing target.

### 4.4 Landing

`LandingResolution.Resolve` (shared) picks the target:
1. Fall height (peak since leaving the ground minus current height) ≥ `HardLandingHeightThreshold` (120 studs): **HardLanding**.
2. Crouch on: CrouchIdle/CrouchWalk.
3. Moving forward with `preAirborneLocomotion` set: back into Run/Sprint. It's set when you leave the ground from Run/Sprint, or from Slide/SlideJump (then it's the tier the slide was entered from, tracked as `slideEntryLocomotion` on both sides; 2026-09-28). A vault keeps it, so you land back into your sprint after one (§4.8, 2026-09-28).
4. Otherwise Walk or Idle.

- **Medium landing** (client-only feel): fall height ≥ `MediumLandingHeightThreshold` (60) lands normally but with `WalkSpeed` × 0.7 for 0.55 s.
- **HardLanding:** `WalkSpeed` 0 and jump blocked for `HardLandingDurationSeconds` (1.11 s, the clip length). Ends early only if the floor disappears. **Server-enforced** (§8.5).
- Fall height survives Airborne↔DoubleJump/WallRun/WallLeap/WallCling/WallBoost/Vault/LedgeJump hops, so a cling partway down a long fall doesn't erase it. Swimming resets it.

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

A mantle assist, not a climb: when a jump comes up just short and the lip is around your chest or head, Space puts you on top. Tall walls are WallCling's job. The Sorcery reference and the reasoning behind every difference from it are in Appendix C.

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

**Motion** (one state, two phases; the whole state lasts `VaultDurationSeconds`, 0.4 s; it was the Vault clip's 0.32 s length until the 2026-09-28 retune):
1. **Mantle** (at most `VaultMantleSeconds`, 0.2 s; shorter when you're already rising faster, so the mantle runs at your own upward speed and a fast boost carries straight over the lip instead of braking): a full-force velocity override carries the root straight up the wall face until the feet are `VaultMantleClearance` (0.5) above the top, then straight across onto it, at one constant speed (`TraversalMath.VaultMantlePoint`; each frame aims for where the path will be at the end of that frame, so it arrives on time). Rising first keeps the body clear of the lip. The rise is the ledge height plus the clearance (up to 6.5 studs); the leg across is at most reach + inset (4.25 studs). Facing is locked into the wall. It replaced a one-frame `PivotTo` snap that read as a teleport (2026-09-25 playtest).
2. **Launch:** when the mantle ends, one-shot velocity writes along the camera's flattened look: `VaultForwardSpeed` (70) forward plus `VaultHorizontalMomentumKeep` (40%) of the entry horizontal velocity, and `VaultUpwardSpeed` (50) plus |vy| × `VaultVerticalMomentumKeep` (1/3) up, the fall-speed part capped at `VaultMaxMomentumUpward` (20). At most 70 up. (Sorcery's 15 forward / 35 up were the starting point; retuned 2026-09-28.)
3. **Window:** the rest of `VaultDurationSeconds`, then Airborne, which lands on the ledge (a 50 up launch comes back down in about 0.5 s). Landing isn't checked at all until the window ends: the feet pass just above the ledge, and a mid-vault read used to resolve a landing (often a resumed Run) instead of handing to Airborne (2026-09-25 playtest). Jump is blocked for the whole state, so the Space press can't also fire a Humanoid jump.

**Keeps your sprint** (designer, 2026-09-28; it used to always land you walking): a vault leaves `preAirborneLocomotion` alone, so its landing resumes Run/Sprint when you're still moving forward, like any other airborne move, and Vault has Run/Sprint edges for it. A Flow sprint chain carries through a vault that lands back in Sprint (§4.9).

**After a vault:** the double jump isn't spent, but DoubleJump is blocked for `VaultDoubleJumpBlockSeconds` (0.25 s). Facing is locked to the launch direction during the window.

### 4.9 Flow

Not a state: a 0-1 value that chaining traversal moves inside a sprint builds up, raising the fast tiers' real, server-enforced speed cap. Built 2026-09-28 from reference footage (Kaizen 2) where chaining wall runs, slides, vaults and leaps visibly raises top speed and it fades once you stop.

- **Sprint chain** (`Shared/Movement/FlowRules.luau`, shared): starts on entering Sprint, survives every airborne and slide state after it, and ends on touching down in any other grounded state (Walk, Idle, Run, Crouch, HardLanding). Flow only gains inside it and drops to zero the moment it ends; landing back into Sprint (after a vault too) keeps it. Designer, 2026-09-28, after a playtest built Flow from Walk and Run takeoffs.
- **Gain:** entering SlideJump, WallRun, WallLeap, WallBoost, Vault or DoubleJump (`MovementStateGroups.FlowBuilding`) adds `FlowGainPerMove` (0.2), capped at 1. WallCling is a hold (the boost from it counts). Sprint itself never builds it, so sprinting in a straight line doesn't.
- **Drain:** nothing for `FlowDecayDelaySeconds` (1.5 s) after the last gain, then `FlowDecayRate` (0.33) per second, full to zero in about 3 s. Linear and closed-form, like `SlideDecayRate`. Only a move's entry counts, so a wall run longer than the delay starts draining mid-run.
- **Effect:** horizontal speed × `TraversalMath.FlowMultiplier`, `1 + flow × FlowMaxSpeedBonus` (0.5, so up to 1.5×):
  - **Sprint:** `CharacterMover` re-applies it to `WalkSpeed` every frame (`SetSpeed(speed, true)`), so the bonus drains with Flow instead of sticking at its value on `Enter`.
  - **WallRun:** `WallRunSpeed` × the multiplier, read every tick.
  - **Slide:** the entry clamp only (`TraversalMath.SlideCeiling`). The entry velocity already carries the bonus, so scaling the output would count it twice. SlideJump uses the same ceiling, never below the slide's own speed.
  - **Launches** (SlideJump, WallLeap, Vault) aren't multiplied: they build on the speed you had. Nothing vertical changes, so the vertical ceiling needs nothing. Run, Idle, Walk and Crouch never have Flow.
  - At full Flow: Sprint 60, WallRun 52.5, slide ceiling 75; the WallLeap bound goes from about 166 to 173.
- **Server:** keeps its own Flow (`MovementValidationService/Flow.luau`), never read from the client. It gains in `TransitionBookkeeping` after the landing-grace snapshot, and drains in its own Heartbeat step, not in `Mirror.PassiveTransitions` (claim handlers run that too, so it would drain extra). Caps are in §8.2.
- **Server at or above the client:** the server gains one claim lag after the client, but claim lag varies: a fast claim then a slow one would leave it draining longer between them than the client did. So its drain starts one `ClaimTiming.ClaimLagSeconds` later than the client's, the same idea as the vertical ceiling's late descent. `Flow.spec` simulates jittered arrivals and fails without it. A move the client counts but the server rejects still leaves the client ahead (§14).
- **Name:** Flow, not momentum, which the codebase already uses for residual velocity (the landing-momentum grace, `VaultHorizontalMomentumKeep`). Separate from `context.qinggong`, which waits on a combat decision.
- **Debug:** client and server Flow on the F4 Movement tab; the four `Flow*` constants are live-tunable (§10). A developer-only test meter (`FlowBarController` + `Assets/UI/FlowBar.model.json`) draws Flow as a vertical bar on the left edge; remove both files and its `default.project.json` entry to drop it.

### 4.10 LedgeJump

Jump right at a drop-off while moving fast and you get a forward burst instead of just falling off: a deliberate, timed move, the grounded counterpart of SlideJump and WallLeap. Built 2026-09-28 from reference footage. It isn't Vault (a mantle *onto* a ledge you came up short of) and it isn't a passive walk-off boost: walking off an edge stays a plain Airborne fall.

- **Trigger:** a jump from Run or Sprint (designer, 2026-09-28: a movement move, so the speed tiers only), or a slide jump, since Slide is only reached from them. Walk and Idle jumps never ledge jump.
- **Gates** (`CanEnter[LedgeJump]`): a drop ahead (`context.ledgeDropAhead`, only ever set for a jump takeoff), `preAirborneLocomotion` Run or Sprint, and real horizontal speed ≥ `LedgeJumpMinEntrySpeed` (22). That's real speed, not the tier's label, so any settled Run qualifies and one still accelerating doesn't.
- **Probe** (`SpatialQueries.QueryLedgeDropAhead`), along the travel direction (velocity, not facing): nothing between the root and a point `LedgeJumpProbeForwardDistance` (3) ahead, and nothing within `LedgeJumpProbeCastDistance` (12, so 9 studs below the feet) under that point. A step or wall ahead isn't a drop, and the first check keeps the down cast from starting inside one, where a raycast would miss it.
- **When:** the client tries it once, on the Airborne entry of the takeoff: the first airborne frame, with the root still at the edge, after the takeoff's own bookkeeping. The path is Run/Sprint → Airborne → LedgeJump → Airborne in one tick (Slide → SlideJump → Airborne → LedgeJump → Airborne for a slide jump).
- **Launch:** one tick, like SlideJump: the horizontal velocity plus `LedgeJumpBurstForce` (20) along it (`TraversalMath.LedgeJumpVelocity`), a one-shot write, with `WalkSpeed` set to the launched speed for air control. Vertical is left alone: a plain jump keeps its `JumpPower` launch and a slide jump its 63, so the vertical ceiling needs nothing new.
- **Landing:** the takeoff already set `preAirborneLocomotion`, so landing with forward held resumes Run or Sprint (§4.4).
- **Flow:** in `FlowBuilding` and `FlowHolding`. A Sprint ledge jump builds Flow; a Run one doesn't, since Flow only exists in a sprint chain (§4.9).
- **Server (inferred, never claimed):** the mirror goes Airborne on the state label, which reaches the server 0.15-0.2 s before the positions (§9). A drop probe run then would start 6-8 studs short of the edge at sprint speed and find ground. So:
  - The mirror's takeoff from Run, Sprint, Slide or SlideJump arms a watch for one `ClaimTiming.ClaimLagSeconds` (`TransitionBookkeeping`).
  - Each Heartbeat after the mirror, `LedgeJump.ResolveTakeoff` waits until the support probe loses the floor, then judges once. It has to be a jump: the label read Jumping at the takeoff, it came from a slide jump, or the root is now above where it last stood (a walk-off never rises, so a missed jump label is still caught). The drop probe runs from the last grounded root and the first airborne one, which bracket the lift-off. Then the same `CanEnter`.
  - Accepted: Airborne → LedgeJump → Airborne. The airborne allowance becomes `TraversalMath.LedgeJumpMaxHorizontalSpeed`: the burst on top of the most the character could carry at takeoff (the cap, or the last grounded Heartbeat's cap plus floor speed), kept for the flight. The cap difference is credited back to the last grounded sample, where the burst began.
  - If the client's double jump reached the mirror first, the mirror's DoubleJump ends early, as for a pending wall claim (§8.4). Any other state in between drops it (§14).
- **Why Airborne → LedgeJump**, not Run/Sprint → LedgeJump as first drafted: the server can only confirm a ledge jump once its mirror is already Airborne, and both sides take the same edge.
- **Animation and cues:** a `LedgeJump` folder in `Movement.model.json` of variant clips (`Variant1`-`Variant4`, named in `LocomotionAnimator`'s `LEDGE_JUMP_VARIANTS`), one picked at random per ledge jump and never the same one twice in a row, held after the one-tick state like SlideJump's. A blank variant is skipped; with none authored the plain Jump clip plays. Adding a variant is a new Animation in the folder plus its name in the list. The cue row only holds FOV.
- **vs WallLeap:** both are a jump-timed forward burst, but from different places (a wall run vs a grounded takeoff at a drop) and they can't overlap.

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
| Airborne | Grounded set, DoubleJump, WallRun, WallCling, Vault, LedgeJump |
| DoubleJump | Airborne, grounded set, Vault |
| HardLanding | Grounded set (minus itself), Airborne |
| WallRun | Airborne, grounded set, WallLeap |
| WallLeap | Airborne |
| WallCling | Airborne, WallBoost, grounded set, Vault |
| WallBoost | Airborne, grounded set, Vault |
| Vault | Airborne, grounded set |
| LedgeJump | Airborne |

Every state that can land has an edge to every state `LandingResolution.Resolve` can return; a require-time assert enforces it (a missing edge once stranded both sides in WallRun/WallCling after landing).

---

## 6. Physics, facing, animation and collision

- **Speed tiers** are `Humanoid.WalkSpeed`; `UseJumpPower = true` with `JumpPower` from tuning. A medium-landing slow is a timed multiplier re-applied every Heartbeat.
- **`CharacterMover`** is the only code that touches the Humanoid/root part:
  - `SetVelocityOverride(velocity, maxForce?)`/`ClearVelocityOverride` drive one `LinearVelocity`, created once per life and left inert between uses (world-relative, `ForceLimitMode = PerAxis`). Per-axis force lets DoubleJump drive only Y and Slide only X/Z.
  - `SetHorizontalVelocity`/`SetVerticalVelocity` are one-shot writes for launches that hand off in the same tick (SlideJump, WallLeap, WallBoost, Vault, cling drop). A constraint there would never get its `Exit` to clear it.
- **Facing:** `FacingController` flips `Humanoid.AutoRotate` every frame: off plus face-the-camera while `MouseBehavior == LockCenter` (Shift Lock/first-person), on otherwise. States can set a lock direction (WallRun faces along the tangent); zero vectors mean "no lock".
- **Animation:** `LocomotionAnimator` destroys the default `Animate` script, loads the clips from `Assets/Animations/Movement.model.json` (a blank `AnimationId` is skipped, not an error) and crossfades on state changes (`AnimationFadeTimeSeconds`).
  - Walk has 8 directional clips when the camera is locked. Switching direction starts the new clip at the old one's gait phase, so the crossfade doesn't swap feet. Unlocked it always plays Forward, which avoids stutter while `AutoRotate` swings.
  - Airborne plays Jump/Fall from the Humanoid state. Landing overlays `Land` for `LandingAnimationHoldSeconds`; HardLanding plays `LandHard` for its whole state.
  - One-tick states (SlideJump, WallLeap, LedgeJump) are shown with a transient hold.
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
| `MovementDebugState` | S→C | Mirrored state, run duration, Speed violations, server Flow (developers, overlay open only) | Unreliable |
| `PlayMovementCue` | S→C | Player + state name, to everyone but the mover, for "Nearby" cues (§15.5) | Unreliable |
| `RequestSetTuning` / `TuningState` | C→S / S→C | One override / the session's effective tuning list | 5/s, dev-only |
| `RequestSetNoclip` / `NoclipState` | C→S / S→C | Noclip on/off | 2/s, dev-only |
| `RequestDevTeleport` | C→S | Position (NaN/inf rejected) | 3/s, dev-only |
| `RequestSetDebugOverlayOpen` | C→S | Overlay open | 5/s, dev-only |

- **What needs a claim.** Only things the server can't see: Run (double-tap), Sprint (dwell), crouch and camera-lock *levels* (no replicated equivalent), and the traversal moves. Idle/Walk/Airborne/landings/slide/slide jump/ledge jump are mirrored passively from replicated Humanoid state, `MoveDirection` and server probes.
- **Levels, not edges:** crouch and camera lock are sent on every change **and** resent every 1 s (`CLAIM_RESYNC_INTERVAL_SECONDS`), as are Run/Sprint while held. A dropped packet heals within a second. Crouch is sent even mid-air, so a crouched landing is decided correctly.
- **Crouch is the effective level:** the client folds in its slide-jump crouch-lock (§4.2) and resends when it arms. The server used to keep its own copy, armed when its mirror saw the slide jump, but a slide jump off a ledge shows the Jumping label for about a frame, so the mirror often saw a slide-off instead, missed the lock and landed crouched while the client ran on (fixed 2026-09-28). Sending the effective level trusts the client with nothing new: it can already send any level.
- **No rejection messages:** the server never tells the client "no". Exits are inferred on both sides from the same geometry and timers.

---

## 8. Server validation

`Server/Services/MovementValidationService/`, one `PlayerSession` per character life (own `Trove`, destroyed on death, removal, respawn or leave). The Heartbeat order matters and is documented at the loop in `init.luau`: support probe → root history → fall height → wall probes → passive mirror → buffered claim retries → ledge-jump takeoff → slide ground → speed check → vertical ceiling → debug broadcast.

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
| `Flow` | The server's own Flow: gain, held multiplier, drain (§4.9, §8.2) |
| `LedgeJump` | Judges a watched takeoff as a LedgeJump once the positions show the lift-off (§4.10) |
| `TraversalClaims` / `TransitionClaims` | `ClaimTraversalMove` / `RequestMovementTransition` and their claim buffers (§8.4, §8.1) |
| `Violations` | Violation trackers and `MovementViolation` (§8.7) |
| `DebugBroadcast`, `DebugFlags` | The F4 overlay broadcast; every capture/logging switch (§10) |

### 8.1 Mirror and "grounded"

- **The mirror** is built from the same `StateRules`. Passive transitions (Idle/Walk/Airborne, landings, slide decay, crouch states, Sprint→Run demotion) are decided by the server itself every Heartbeat. Claims are checked with the same `CanEnter`, against the server's own context.
- **Run/Sprint claims** re-mirror first (support, then the passive mirror), like traversal claims (§8.4), so a landing that has replicated resolves (HardLanding included) before the claim is judged. Then Run is claimable only from Idle/Walk and Sprint only from Run (`StateRules.CanClaimFrom`, the same rule the client's double-tap uses). The other edges into Run/Sprint are landings each side resolves itself; a claim along them used to end a HardLanding lock or a Vault early and skip the mirror's landing resolution (fixed 2026-09-28). The double-jump and takeoff-tier resets happen on every grounded entry (`TransitionBookkeeping`), as on the client, not only in the mirror's landing branches.
- **Support probe** (`SpatialQueries.QuerySupport`): the R6 leg footprint (2×1, turned with the rig's yaw) swept 4 studs down from the root, collidable non-water geometry only. It's the server's ground truth.
- **Grounded for the mirror** (`Probes.IsGrounded`) = support **and** a grounded Humanoid label, or support that has lasted a full 0.5 s window while labelled airborne. A client can't fake a landing mid-air (DoubleJump refresh, fall height) or claim to be airborne while standing to keep air caps.
- **Intent:** `classifyMoveIntent` rebuilds forward/backward/strafe from `rootPart.CFrame` vs `MoveDirection`. Both are client-written, so they only choose mirror tiers; every tier they unlock is still enforced against real displacement. They also arrive on different streams: `MoveDirection` is a Humanoid property and leads the facing (position stream) by about 0.15-0.2 s (§9), so a camera turn while holding W briefly reads as a strafe. A forward reading therefore counts for one `ClaimTiming.ClaimLagSeconds` after it was last seen (`Context.RecordForward`); a real strafe or backpedal outlasts that. Without it, one 0.46 reading demoted a held Sprint to Run and every landing after it resolved to Run (2026-09-28 capture).
- **Crouch at landing:** the crouch level is a claim and leads the positions a landing is read from, so a crouch change newer than one `ClaimLagSeconds` applies on the Heartbeat after a mirrored landing, not to it (`Context.ForLanding`). Otherwise a Ctrl press just after touching down (a quick hop into a slide) landed the mirror in CrouchWalk where the client had landed in Sprint and slid (2026-09-28 capture).
- **Sprint:** the server times Run itself, restarting the clock on every entry into Run (including a landing that resumes Run, fixed 2026-09-28; its own entries are backdated one `ClaimLagSeconds`, since it sees the landing that much after the client), backdated by half the measured ping (capped at half the threshold). A Sprint claim that lands milliseconds short of the dwell is buffered and retried. Backpedal demotion only runs while the camera is locked (from the `CameraLocked` level claim), because unlocked, facing deliberately lags movement. A new lock counts one `ClaimLagSeconds` after its claim arrives (unlocking applies at once). The claim leads the snapped facing, which rides the position stream, so turning the camera while sprinting unlocked and then locking read as a strafe against the old facing. That dropped the mirror to Run for the whole 3 s dwell (fixed 2026-09-28). The landing decision reads the same delayed lock.

### 8.2 Horizontal speed budget

- **Budget:** every Heartbeat adds `(effective cap + trusted floor speed) × dt`. Every 0.5 s (`SpeedCheckIntervalSeconds`) the real X/Z displacement is compared with budget × `SpeedToleranceMultiplier` (1.3, unmeasured, §9).
  - Transitions never reset the window, so it's judged against exactly the caps that were live, and a client toggling states can't discard evidence.
  - Over budget: snap X/Z back to the window start and zero horizontal velocity.
- **Caps by state:**

| State | Cap |
|---|---|
| Idle, Walk | 18 |
| Run | 28 |
| Sprint, Airborne, DoubleJump, WallLeap, WallBoost, Vault, LedgeJump | 40 |
| CrouchIdle, CrouchWalk | 9 |
| Slide, SlideJump | 50 + slope amplification |
| WallRun | 35 |
| WallCling | 0 |
| HardLanding | 6 (unmeasured) |

- **Flow (§4.9):** Sprint and WallRun caps are multiplied by the server's live Flow multiplier. Slide, SlideJump and the airborne family use the **held** multiplier: the highest since the current slide or flight began, cleared on landing, because the client's speed there was fixed at launch and doesn't drain with Flow. Allowances (WallLeap, SlideJump, Vault) are computed from Flow-raised speeds at the accept and not multiplied again. The server gains one claim lag after the client, and starts draining one `ClaimTiming.ClaimLagSeconds` later than the client, so uneven lag between two claims can't leave it below the client (simulated in `Flow.spec`).

- **Airborne allowance** (`airborneAllowedSpeed`): WallLeap (the exact bound, about 166), SlideJump (50) and LedgeJump (the takeoff's carry speed plus `LedgeJumpBurstForce`, §4.10) raise the air cap for the whole flight, since nothing slows horizontal flight. A Vault raises it only if `VaultMaxHorizontalSpeed` (`VaultForwardSpeed` plus 40% of the cap in force before it) is above the cap, which it is at shipped tuning (70 + 0.4 × 40 = 86 against 40).
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
- **Vault:** the server probes the ledge only at claim time and on buffered retries (a vault has no sustain check). The client's mantle carries its root up and onto the ledge right away, and those positions can reach the server before the claim is judged; from up there no wall is in front of it. So `Probes.UpdateLedgeQuery` tries the current root, then each root CFrame recorded in the last claim lag (`Probes.RecordRootHistory`, every Heartbeat), newest first, and the facing check uses the facing of whichever position found the ledge. A rejected Vault is buffered like DoubleJump while the mirror is in Airborne, DoubleJump, WallCling or WallBoost. A WallRun or WallCling claim waiting while the mirror is still in its (later-timed) Vault ends that Vault early, the same as DoubleJump; otherwise a cling right after a vault was dropped (2026-09-28). The cooldown clock is the accept time, backdated by any time buffered. The launch direction comes from the client's camera and isn't checked; its magnitude is bounded (§8.2, §8.3).
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
| LedgeJump takeoff watch = `ClaimLagSeconds` | Derived, 2026-09-28 | The label that takes the mirror airborne leads the positions that show the lift-off (0.15-0.2 s, below); the window already sized for that ordering |
| Forward-intent hold (`Context.RecordForward`) = `ClaimLagSeconds` | Derived, 2026-09-28 | `MoveDirection` (Humanoid property) leads facing (position stream) like the state label does (0.15-0.2 s, below). A capture caught a single 0.46 reading while W was held demoting Sprint |
| Camera-lock delay (`Context.Build`) = `ClaimLagSeconds` | Derived, 2026-09-28 | The lock claim leads the facing snap it causes, which rides the position stream (0.15-0.2 s, below) |
| Landing crouch delay (`Context.ForLanding`), Run-clock backdate on the mirror's own Run entries, both = `ClaimLagSeconds` | Derived, 2026-09-28 | Claims (crouch level) lead positions; the mirror saw landings 0.13-0.42 s after the client in the same capture (the Sprint claim buffer covers the tail) |
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

**Live tuning:** `MovementTuning.luau` lists the tunables (62 today) with valid ranges. Overrides are per player, dev-only, bounds-checked server-side, applied to both client feel and server enforcement, and cleared on leave. A live change re-applies the current tier's `WalkSpeed` immediately. Adding a tunable touches `MovementConstants`, `MovementTuning` (name + range), the `TunableConstantName` enum in `network.zap`, and a new `Row_*` in the overlay (built in Studio). Validation tolerances are never tunable.

**Flags** (all `false` in committed code; flip for a playtest, then flip back):

| Flag | File | Prints |
|---|---|---|
| `SPEED_RATIO_CAPTURE` | Validation `DebugFlags` | p50/p99/p99.9/max of displacement ÷ budget every 200 windows, plus `zeroBudgetDriftMax` |
| `VERTICAL_CEILING_DEBUG_LOGGING` | Validation `DebugFlags` | Every frame above the ceiling: y, ceiling, apex, excess, lag |
| `JUMP_LAUNCH_CAPTURE` | Validation `DebugFlags` | Per landing: from-state, peak, time to peak, implied launch speed |
| `SPEED_SANITY_DEBUG_LOGGING` | Validation `DebugFlags` | Cap changes, rate-limited claims, Sprint dwell overshoot, rejected claims |
| `WALL_TRAVERSAL_DEBUG_LOGGING` | Validation `DebugFlags` | Rejected WallRun/WallLeap claims, WallRun force-exits |
| `LANDING_DEBUG_LOGGING` | Validation `DebugFlags` and client `Movement/init.luau` | Every transition on each side (`[Transition] server/client`) with the inputs the landing decision reads: takeoff tier, forward/backward, camera lock, crouch, grounded |
| `WALLCLING_DEBUG_LOGGING` | SpatialQueries | Why a cling cast was rejected |
| `WALLRUN_DEBUG_LOGGING`, `WALLCLING_TRACE_LOGGING` | Client `Movement/init.luau` | Client-side wall probe traces |
| `ANIMATION_LOAD_DEBUG_LOGGING` | LocomotionAnimator | Clip loading |

Always on in Studio only: `[MovementViolation]` for every correction, `[TraversalClaim] ... REJECTED` for DoubleJump/WallBoost/Vault claims.

---

## 11. Constants

Everything is in `Shared/Constants/MovementConstants.luau`, with the reasoning next to each value. Groups:

- **Tunable (F4):** speed tiers and jump; Run/Sprint timing; crouch/slide; landing thresholds and durations; DoubleJump; slide slope; WallRun/WallLeap feel; WallCling/WallBoost timings and forces; Vault launch, mantle time, duration, facing, cooldown and double-jump block; LedgeJump entry speed and burst; animation fade/hold.
- **Structural (not tunable):** cast sizes and reaches (`GroundQueryCastDistance`, `GroundSupportFootprint`, `WallRunSideCast*`, `WallClingDistance`/`CastSize`, `WallDetectMaxUpDot`, `WallClingMaxNormalY`, the `Vault*` ledge geometry: reach, height window, inset, depth, top normal, headroom, mantle clearance; `LedgeJumpProbeForwardDistance`/`CastDistance`), rig facts (`RigRootHeightAboveFeet`, `TerrainVoxelSize`), `DirectionEpsilon`, `ClimbableTag`, `SlideJumpUpwardSpeed`, `WallClingDropSeparationSpeed`.
- **Validation (never tunable):** `SpeedCheckIntervalSeconds`, `SpeedToleranceMultiplier`, `WallRunClaimBufferSeconds`, `WallClingSpeedCeiling`. Network-layer limits (claims per second) live in the services, not here.

A number goes in only once it's a real decision, never as a placeholder. Starting-point values are marked as such in their comments.

---

## 12. Tests

`lune run tests/run` (CI runs it after `wally install`). `tests/harness.luau` maps the Rojo tree onto files so shared modules load unmodified. The specs cover StateRules (topology, CanEnter, WallLeap-chain rule, LedgeJump gates, claim sources), LandingResolution, StateMachine, MovementTuning (name/range parity), TraversalMath, Flow and FlowRules (the sprint chain, including LedgeJump). Flow's include a simulation that the server's Flow never trails the client's under jittered claim lag, and that the Flow-raised WallLeap and slide bounds still bound the client. That includes simulations proving `DoubleJumpMaxRise`, `DoubleJumpTimeToApex`/`DescentCeiling`, `WallLeapMaxHorizontalSpeed` and the Vault bounds (`VaultMaxRise`, `VaultMaxUpwardSpeed`, `VaultMaxHorizontalSpeed`) and `LedgeJumpMaxHorizontalSpeed` bound the client's real motion. `QueryLedge` and `QueryLedgeDropAhead` need real geometry, so playtests cover them, not specs. Presentation has its own pure specs: `Spring`, `MovementCues`, `CueDebounce`, `MovementStateNames` (network.zap enum parity) and `FootstepPack` (§15).

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
| Vault | A mantle assist: Space at a chest-to-head-high lip, automatic during WallBoost, camera-steered launch, no health scaling, keeps your sprint (§4.8) |
| Dash | Skipped |
| LedgeJump | A jump from Run/Sprint (or a slide jump) at a drop-off adds a forward burst; walking off doesn't; vertical unchanged; inferred by the server, never claimed. Separate from WallLeap, the other jump-timed burst, which only leaves a wall run (§4.10) |
| Flow | Chaining traversal moves raises the fast tiers' real, server-enforced cap (up to 1.5×), decaying after a pause; named Flow, not momentum (§4.9) |
| WallLatch | A separate system, not part of wall run |

---

## 14. Known gaps and future work

**Needs a Studio playtest (with incoming replication lag on):**
- Size `SpeedToleranceMultiplier` and `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE` from `SPEED_RATIO_CAPTURE` (audit M-007, M-015, M-016, M-017).
- Record the `StreamingMinRadius`/`StreamingTargetRadius` values (ARCHITECTURE §14).
- Tag real ladders `Climbable`.

**Needs a playtest (Vault, §4.8):** check the mantle's feel (`VaultMantleSeconds` is live-tunable; much shorter than 0.2 s starts to read as a snap again, though a fast boost already mantles at its own speed); check whether the launch after a fast boost still reads as braking: it caps the upward speed at 70 (`VaultUpwardSpeed` + `VaultMaxMomentumUpward`), and raising `VaultVerticalMomentumKeep`/`VaultMaxMomentumUpward` keeps more of the boost (the server bound follows the same tuning); check that the Humanoid doesn't register the ledge as ground right after the mantle, before the launch lifts off (that would end the vault as a landing); check how high above a cling the automatic boost vault still reaches: `WallBoostSeparationSpeed` (12 st/s) carries you away from the wall, out of the 3-stud reach after roughly 0.15-0.2 s (about 15-18 studs of rise) unless holding W pulls you back. `WallBoostSeparationSpeed` is live-tunable to try 0.

**Needs a playtest (Flow, §4.9):** watch client vs server Flow on the F4 Movement tab (server should read at or above client); check for Speed violations while chaining at full Flow. Open feel questions: should a long WallRun keep Flow from draining (today only entry counts, so it bleeds mid-run)? Is sprinting at +50% for about 4.5 s after a chain OK (stopping or backpedalling already ends the chain)? All four `Flow*` constants are live-tunable.

**Needs a playtest (LedgeJump, §4.10):** add the three remaining clips' `AnimationId`s to `Variant2`-`Variant4` in `Movement.model.json`'s `LedgeJump` folder; check the burst doesn't draw Speed violations, including with incoming replication lag on (the server judges it from the position stream); check whether keeping the jump's own height reads as "diving off a ledge" or wants its own `LedgeJumpUpwardForce` (it would then need a vertical-ceiling raise); check the probe distances against real level geometry (a drop has to be more than 9 studs to count). `LedgeJumpMinEntrySpeed` and `LedgeJumpBurstForce` are live-tunable.

**Needs a playtest (vertical ceiling after a DoubleJump):** a 2026-09-28 capture showed the ceiling re-anchoring to "one jump" *after* an accepted DoubleJump (`raisedBy=0`, `sinceAnchor` later than the accept), likely the support probe touching a ledge while rising past it, which drops the DoubleJump's remaining rise. Capture with `VERTICAL_CEILING_DEBUG_LOGGING` before changing the anchor (a candidate fix: an anchor never lowers a ceiling whose apex is still ahead).

**Presentation (§15):**
- Exact FOV, shake and stride numbers are starting points; tune in playtests.
- **Other players' footsteps** still come from Roblox's default `Running` loop (§15.3.2). They could be derived on each client from replicated velocity with no network cost (useful for positional awareness); decide separately.
- **Camera clipping with shift lock:** the shoulder offset is applied after Roblox's occlusion handling (Poppercam), so against a wall the offset camera can clip into it. The reference behaves the same way. If it shows up, cast from the focus to the offset position and shorten the offset.
- **Smooth facing in shift lock:** the reference turns the character toward the camera gradually; `FacingController` snaps. Adding it would be a `FacingController` change, and the server's forward check compares facing to movement (§8.1), so a lagging turn would need checking against it first.
- Cue rows for `WallCling`, `WallBoost`, `DoubleJump`, `SlideJump`, `LedgeJump`, `Airborne`: empty (or FOV-hold only) until someone wants them. A Flow cue (speed-line intensity, an FOV kick) can read `context.flowMultiplier`.
- **Vault sounds and particles:** its row names `VaultWhoosh` and `VaultDust` (local and Nearby), not authored yet, like the other impact cues. A light `CameraShake` is one more row field if the kick alone feels flat.
- A volume slider (the `SoundGroup`s are ready) and an effects-quality or reduced-motion setting. Both are new product scope and need a persisted preference (ProfileStore, ARCHITECTURE §13).
- As more effect files land, extend `FootstepPack.spec.luau` into a spec checking that every name in `MovementCues` is mounted somewhere in the template.

**Residuals (accepted for now):**
- The ceiling's height stacks rises: a DoubleJump on the way down still allows its full rise on top of the old ceiling (at most about one jump over legit play, never unbounded).
- Being knocked upward by another player isn't a server-known impulse.
- A Vault claim delayed past a speed window after its mantle (a resent reliable packet) misses the displacement credit, and that window can correct the mantle.
- CFrame- or tween-driven moving platforms report zero velocity and get no floor credit. So do client-owned platforms and vehicles.
- The crouch-lock's `CrouchUp` goes out with the slide jump, and a landing within one claim lag of it still reads the old level (`Context.ForLanding`). A slide jump's flight plus the position lag outlasts that window, so only a very high ping and a landing near the apex could land the mirror crouched.
- If crouch and jump are pressed within one network leg, the jump can reach the server before the crouch. The flight is then capped at 40 instead of the slide-jump 50. Not seen in playtests.
- Skimming within about a stud of a surface after a launch's apex, then flying on for over 1 s, loses the airborne allowance.
- A modified client can claim crouch to use the crouched collision group through `CrouchPassable` geometry.
- Flow: a move the client counts but the server rejects or never receives leaves the client's Flow ahead of the server's, so its Sprint/WallRun can outrun the cap until the chain ends or the extra drains. The airborne cap uses the held multiplier for any takeoff, even a Walk jump.
- LedgeJump: a WallRun, WallCling or Vault the mirror enters before its positions show the lift-off drops the ledge jump there. Only the burst before that move and one Flow gain are left unaccounted for, within the speed tolerance. The server is lenient in the other direction: its probes bracket the lift-off, so it can confirm a jump taken a little further from the edge than the client's probe allows, and it judges the speed gate on the launched speed.
- LedgeJump: a Run/Sprint jump the mirror sees from Walk (a lost Run claim) isn't watched, so its burst is corrected.
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

## 15. Presentation: sound, particles, camera and shift lock

How movement gets its juice: sounds, particles, camera FOV, camera shake and our own shift lock. Purely visual: nothing here changes how movement behaves (§15.0).

**Status:** code complete. Footsteps have their sound pack; the other cues have no sounds or particles yet. The camera, FX mount and Nearby replication still need a Studio playtest (two players for Nearby, once impact sounds exist). Open questions are in §14.

### 15.0 Decisions

| Question | Decision |
|---|---|
| Can polish affect gameplay (speed, hitboxes, legality)? | **No.** It only reads the movement FSM and never writes to it, `CanEnter` or physics. Anything that affects gameplay (for example a slow-motion parry effect) is a combat decision, routed through `CombatConstants`. |
| How does a state get its polish? | One data table, `Shared/Presentation/MovementCues.luau`, maps each `MovementState` to its cues. The controllers walk that table generically. **A new state's polish is a new table row, not new code** (§15.1). |
| Where do the instances come from? | Authored in Studio as one R6 rig template (`Assets/FX/Movement`), which the server mounts onto every character. Nothing rig-attached is built with `Instance.new` (same spirit as ARCHITECTURE §8) (§15.2). |
| Replication | Each row declares `Replication: "Local" \| "Nearby"`. `"Local"` never leaves the mover's client. `"Nearby"` one-shots are **sent by the server**, driven by its own mirrored FSM, to everyone except the mover. There's no client→server cue request (§15.5). |
| Shift lock | **Our own implementation**, adapted from the designer's reference code, replacing Roblox's default mouse lock (§15.4.3). |
| Smoothing | A small in-repo damped spring, `Shared/Util/Spring.luau`, not a Wally dependency. It's a spring rather than `TweenService` so a goal that changes mid-blend (Sprint → Slide → Sprint in under a second) carries its velocity instead of popping (§15.4.1). |
| Footsteps | Driven by distance travelled, not by state entry. The cue table supplies the sound and stride per state (§15.3.2). |
| Live-tunable in the F4 overlay? | **No.** That pipeline exists for exploit-relevant physics numbers the server validates (§10). Polish numbers live in `PresentationConstants.luau` and are retuned by editing it. |
| Who sees what | The mover sees and hears every cue. Bystanders get only `"Nearby"` one-shots. Loops, FOV, FOV kicks and camera shake are never replicated. |


### 15.1 The cue table

`Shared/Presentation/MovementCues.luau` is the only place that says which state plays what:

```luau
export type MovementCueDefinition = {
	-- SFX
	EnterSound: string?, -- one-shot on entry
	LoopSound: string?, -- plays while this is the current state
	FootstepSound: string?, -- set name; plays <set><FloorMaterial> every FootstepStrideStuds
	FootstepStrideStuds: number?,

	-- VFX
	EnterParticle: string?, -- :Emit(EnterParticleCount) on entry
	EnterParticleCount: number?, -- nil = PresentationConstants.DefaultEmitCount
	LoopParticle: string?, -- Enabled while this is the current state

	-- Camera
	TargetFOV: number?, -- FOV spring goal while current; nil = BaseFOV unless HoldsFOV
	HoldsFOV: boolean?, -- keep the previous goal (mid-air states)
	CameraShake: string?, -- PresentationConstants.ShakeProfiles key, on entry
	FOVKick: string?, -- PresentationConstants.FOVKickProfiles key, on entry

	Replication: ("Local" | "Nearby")?, -- nil = "Local"
}
```

A state with no row is silent, with base FOV and no shake. Every controller treats that as the correct default, so rows only exist for states that want polish.

**Mid-air FOV.** Airborne, DoubleJump, SlideJump, LedgeJump, WallLeap and Vault set `HoldsFOV`. Without it, every sprint jump would dip FOV back to base mid-air and pump it up again on landing. With it, a jump keeps the FOV it took off with, and a leap off a wall run keeps the wall run's FOV until landing.

**Adding polish to a state:** add or extend its row, and author any new named `Sound`/`ParticleEmitter` in the rig template (§15.2). No controller changes. `tests/specs/MovementCues.spec.luau` checks every row (fields, strides, FOV range, shake profile names, replication values).

#### Reading the table: one-shots vs. sustained cues

`fsm.changed` is **not** a reliable signal for "what state are we in now". SlideJump and WallLeap hand off to Airborne from inside their own `Enter`, so the change fires again while the first change is still being handled. LemonSignal calls the newest connection first, so a handler connected before Movement's main handler receives `(Airborne, WallLeap)` *before* `(WallLeap, WallRun)`. Reading the latest `next` would then leave it on a stale state (the same class of bug as audit M-019). So:

- **One-shots** (`EnterSound`, `EnterParticle`, `CameraShake`) fire from `fsm.changed` on `next`. Order doesn't matter: each event really did enter that state.
- **Sustained cues** (`LoopSound`, `LoopParticle`, `TargetFOV`) are matched to `fsm.current` every frame: if the wanted loop differs from the active one, stop one and start the other. This is idempotent, and it's how `LocomotionAnimator` already picks its clip.

#### Debounce

One-shots skip a replay of the same cue name within `PresentationConstants.MinCueRetriggerSeconds` (`Shared/Presentation/CueDebounce.luau`, used by the SFX, VFX and camera controllers and, per player, by the server's Nearby broadcast). None of today's one-shot states can oscillate (HardLanding needs a 120-stud fall and locks for 1.11 s; WallLeap needs a WallRun first), so this is only a cheap guard against future rows.


### 15.2 Instances: one R6 rig template, mounted by the server

The template syncs to `ReplicatedStorage.Assets.FX.Movement` and mirrors the R6 rig: a folder per body part, holding a folder per existing attachment, holding that attachment's effects:

```
Movement/
    HumanoidRootPart/
        RootAttachment/        HardLandingThud, WallLeapBurst, SlideScrape, WallRunWind, VaultWhoosh (Sounds)
                               HardLandingDust, WallLeapBurst, WallRunTrail, VaultDust (ParticleEmitters)
    Left Leg/
        LeftFootAttachment/    Footstep/ (pack: Plastic, Grass, Metal, Wood, Concrete, Fabric, Sand, Glass)
                               SlideDust (ParticleEmitter)
    Right Leg/
        RightFootAttachment/   Footstep/ (same pack file, mapped again)
                               SlideDust (ParticleEmitter)
```

**Authoring.** The template's folders (part → attachment) are declared in `default.project.json`; effects are added as files saved from Studio and mapped into those folders:

1. Build or collect the effects in Studio **outside** the Rojo-synced tree (e.g. in Workspace).
2. Right-click → *Save to File* into `Assets/FX/` as `.rbxmx`. Sounds alone are simpler as a hand-written `.model.json` (`Assets/FX/Footsteps.model.json` is one; note Rojo 7.7 reads attributes from a lowercase `attributes` key).
3. Map the file into the right attachment folder in `default.project.json`. The project key becomes the instance's name.

A file can hold a single effect or a **pack**: any container of effects (a Folder, or the `SoundGroup` a toolbox pack ships in). The mount flattens a pack onto the attachment, naming each effect `<pack name><effect name>` (a pack `Footstep` holding `Concrete` mounts as `FootstepConcrete`), because a Sound only plays positionally directly under a part or attachment. Set a `SoundGroup` string attribute (`Footsteps`, `Loops` or `Impacts`) on each Sound, or once on a pack's folder for all its sounds. Emitters can be saved enabled or disabled; the mount turns them off.

Only default R6 attachments are used: `RootAttachment` (HumanoidRootPart), `LeftFootAttachment`/`RightFootAttachment` (legs), `LeftGripAttachment`/`RightGripAttachment` (arms), plus the Torso and Head ones if a cue ever needs them. The same name may appear under several attachments (both feet); a cue then drives every instance with that name.

**Mounting.** `Server/Services/MovementCueService.luau` clones the template onto each character on `CharacterAdded`, moving each attachment folder's children onto the rig's matching attachment. It warns if an attachment is missing, and marks the character so it never mounts twice. Mounting on the server means the instances replicate, so a bystander's client can play a `"Nearby"` cue on someone else's character. A client-side clone would exist only on the mover's client.

- **Sound groups:** `SoundGroup`s live in `SoundService` (declared in `default.project.json`). A Rojo model file can't reference instances outside itself, so each `Sound` names its group in a `SoundGroup` string attribute and the mount assigns it (warning if the group doesn't exist). A future volume slider is then one `SoundGroup.Volume` write.
- **Roll-off:** every sound is parented under a part/attachment, so it's positional. The mount sets `RollOffMode = InverseTapered` and `RollOffMaxDistance = PresentationConstants.NearbyRollOffMaxDistance` on sounds used by `"Nearby"` rows, so engine falloff does the distance culling (Roblox's default max distance is effectively map-wide).

**Finding instances on the client.** `CharacterFX` is a small per-character index mapping cue name → instances. It only indexes instances the mount tagged with the `MovementCue` attribute, so the character's other sounds are never picked up. It's built from the character's descendants and kept current with `DescendantAdded`/`DescendantRemoving`, so it doesn't matter whether the mount replicates before or after the client starts listening. A name that isn't there yet is skipped silently, just as `LocomotionAnimator` skips a blank `AnimationId`.

**Preload.** `ContentProvider:PreloadAsync` runs once per client session on the template, in a spawned thread from `MovementController.Init`, so a cue's first play doesn't hitch while its content loads. It isn't repeated each life; the content never changes.


### 15.3 SFX and VFX controllers

`Client/Controllers/Movement/Presentation/SFXController.luau` and `VFXController.luau` sit next to `FacingController`/`LocomotionAnimator` and follow the same pattern: built per life in `Movement/init.luau`'s `setupCharacter`, own a `Trove`, read the FSM and never write it. Each is a small, direct module. The shared thing is the data (`MovementCues`), not a base class.

#### 15.3.1 Shape

- **On `fsm.changed(next)`:** play `next`'s one-shot (`EnterSound` / `EnterParticle`), debounced (§15.1).
- **Every frame:** match loops to `fsm.current` (§15.1).
- **SFX only:** footsteps (§15.3.2), with `PresentationConstants.FootstepPitchJitter` so repeats don't sound identical.

#### 15.3.2 Footsteps

```luau
-- every Heartbeat
local cue = MovementCues[fsm.current]
if not (cue and cue.FootstepSound and characterMover:IsGrounded()) then
	strideAccumulated = 0
	return
end
strideAccumulated += characterMover:GetHorizontalVelocity().Magnitude * dt
if strideAccumulated >= cue.FootstepStrideStuds then
	strideAccumulated = 0
	-- alternate the LeftFootAttachment / RightFootAttachment instance
end
```

**Materials.** Each step plays `<FootstepSound><Humanoid.FloorMaterial>` (`FootstepConcrete`, `FootstepGrass`, ...). For a material the pack has no sound for, it tries that material's alias (`PresentationConstants.FootstepMaterialAliases`, e.g. terrain `Mud` → `Grass`), then `FootstepDefaultMaterial` (`Plastic`), then a plain `<FootstepSound>`. `tests/specs/FootstepPack.spec.luau` loads the pack file and checks that its sound names are real materials, that every alias and the default point at a sound it has, and that its `SoundGroup` exists. Walk, CrouchWalk, Run and Sprint all use the one `Footstep` pack: eight single-step clips, one per surface category, carried over from the designer's previous game along with its material map. The pack is mounted on both feet so consecutive steps alternate instances and each clip has two strides to finish. A separate sprint set would be a second pack and a different row value. Footstep sounds are forced to `Looped = false`, since some packs ship looping sounds.

**Roblox's default footsteps.** `RbxCharacterSounds` gives every character a looping `Running` sound on its root part. `SFXController` mutes it (`Volume = 0`) on the local character only. That script's other sounds (jump, land, swim, climb) are kept, and other players' default running sounds still play.

Distance-based, so cadence scales with real speed without a per-tier timer. The accumulator is also reset on every state change, so switching from Sprint's longer stride to Walk's shorter one doesn't fire an early step. Alternating feet also means one `Sound` isn't restarted every step, which would cut off its tail at sprint cadence (about 6 steps/s).


### 15.4 CameraController

`Client/Controllers/CameraController.luau`, a **flat** module directly under `Controllers/` so `Loader.LoadChildren` loads it (a module inside a plain subfolder is never loaded; Appendix B). Unlike the per-life controllers, it lives for the whole session, so its springs keep their motion across respawns instead of snapping FOV back to base.

#### 15.4.0 Following the current life

The camera can't capture one `fsm`/`Humanoid`: `Movement/init.luau` builds a new `StateMachine` every life. It also can't be handed them by Movement directly (ARCHITECTURE §2: controllers don't reach into each other). Instead a small client module, `Client/State/MovementLife.luau`, publishes the current life:

```luau
MovementLife.Set(life)        -- Movement/init.luau, once per life
MovementLife.Current(): Life? -- whoever needs it now
MovementLife.Started          -- LemonSignal<Life>
-- Life = { humanoid, rootPart, fsm, trove }
```

`Current()` exists because `Loader.SpawnAll` starts every `Init` at the same time, so Movement's first life can begin before the camera subscribes. The camera handles `Current()` once and then `Started`, and connects its per-life listeners to `life.trove`, so they're torn down with that life.

#### 15.4.1 `Shared/Util/Spring.luau`

A damped harmonic spring with a closed-form (exact) step, so it's frame-rate independent: one 1/30 s step lands in exactly the same place as two 1/60 s steps.

```luau
Spring.number(dampingRatio, frequencyHz, initial: number): Spring<number>
Spring.vector3(dampingRatio, frequencyHz, initial: Vector3): Spring<Vector3>
spring:SetGoal(goal)
spring:Update(dt) -> position
spring:Reset(position) -- jump there at rest
```

Both constructors share one implementation (numbers and `Vector3`s support the same arithmetic). The typed constructors give each caller a concrete type, since Luau can't constrain a generic to "supports `+` and `*`". Each step costs a few `exp`/`sin`/`cos` calls; with two springs per frame, nothing is cached. It's pure math and covered by `tests/specs/Spring.spec.luau`.

#### 15.4.2 FOV and shake

- **FOV:** every frame, the goal is the current row's `TargetFOV`, else unchanged if it `HoldsFOV`, else `BaseFOV`, and the spring's value is written to `Camera.FieldOfView`. The default camera scripts never touch FOV.
- **FOV kick:** an `FOVKick` cue (fired from `fsm.changed`, debounced) adds `PresentationConstants.FOVKickProfiles[name].Amount` degrees at once, easing back to zero over its duration with the square of the time left (Sorcery's Quad tween). It's added to the spring's output, not pushed into its goal, so the state's own FOV underneath is untouched and the kick can't fight a `HoldsFOV`. Vault uses it (+10 over 0.5 s; Sorcery's is +20, but ours starts from an already raised sprint or wall-run FOV).
- **Shake:** a `CameraShake` cue (fired from `fsm.changed`, debounced) starts a short random offset from `PresentationConstants.ShakeProfiles[name]` that decays with the square of the time left. It's a pure translation in camera space, so it doesn't need undoing: the default camera script rebuilds its position from the focus every frame and reads only the camera's *direction*, which a translation doesn't change. A rotating shake would drift the camera and would need undoing before the camera script's next update.
- Shake is a decaying random impulse, not a goal-seeking spring, so it isn't built on `Spring`.
- FOV, shift-lock offset and shake all run in one render step at `RenderPriority.Camera + 1`, right after the default camera script.

#### 15.4.3 Shift lock (our own)

Adapted from the designer's reference implementation. Roblox's default mouse lock is off (`StarterPlayer.EnableMouseLockOption = false` in `default.project.json`): it applies its shoulder offset inside the camera module in a single frame, so a spring layered on top would stack two offsets.

- **Toggle:** Left/Right Shift (ignoring input the game already handled), only while a life exists. The life ending (death, respawn) unlocks.
- **Locked:** `MouseBehavior = LockCenter`, re-asserted every frame because the default camera script can release it. `FacingController` and the camera-lock level claim (`not Humanoid.AutoRotate`, §7) key off it, so facing and server validation work unchanged. The mouse icon switches to `ShiftLockMouseIcon`.
- **Shoulder offset:** `ShiftLockOffset` (1, 0.25, 0; pulled in from the reference's 1.75, which read as too far right), eased in and out by `Spring.vector3` with the reference's damping (0.7) and in/out speeds, and applied as a camera-space translation (§15.4.2). It isn't a root-relative `Humanoid.CameraOffset`, which would swing sideways while WallRun locks facing to the wall tangent. Nothing writes `Humanoid.CameraOffset`.
- **First person:** no shoulder offset once the head's `LocalTransparencyModifier` passes `FirstPersonHeadTransparency` or the camera is within `FirstPersonHeadDistance` of it.
- **Not ported from the reference:** its character rotation (facing belongs to `FacingController`; two writers would fight), and its BindableEvent config/toggle hooks (constants live in `PresentationConstants`; add an external toggle when something needs one).

### 15.5 Replication: server-sent "Nearby" cues

```
server mirror FSM changes state (MovementValidationService, TransitionBookkeeping)
  → Server/Events/MirrorStateChanged:Fire(player, next, previous)
  → MovementCueService: MovementCues[next].Replication == "Nearby"?
  → Network.PlayMovementCue.FireExcept(player, { player = player, state = name })
  → other clients: NearbyCuePlayer plays that row's EnterSound + EnterParticle on player.Character
```

```zap
event PlayMovementCue = {
	from: Server,
	type: Unreliable,
	call: SingleSync,
	data: struct {
		player: Instance.Player,
		state: MovementStateName, -- every state by name; shared with the debug overlay
	},
}
```

- **Server-driven:** the server's own mirror decides HardLanding (from its fall height), WallLeap and Vault (on an accepted claim), so bystanders only see moves the server accepted. There's no client request to validate or rate-limit, and no second cue enum to keep in step with the table: the server filters with the same `MovementCues` rows.
- **The payload is the state, not a cue name.** The receiver plays that row's `EnterSound` and `EnterParticle`. It never plays `CameraShake` or `FOVKick`: another player's landing doesn't move your camera.
- **Excluding the mover:** `FireExcept(player, ...)`, because the mover already played the cue locally. As a backstop, the receiver also ignores events about `Players.LocalPlayer`.
- **Receiver** (`Movement/Presentation/NearbyCuePlayer.luau`, callback set once in `MovementController.Init`, so it works while the local player is dead): skips silently if `player.Character` hasn't streamed in (ARCHITECTURE §14) or the named instance isn't there, and skips rows that aren't `"Nearby"`. It finds the instances with `CharacterFX.Scan`, a one-off lookup using the same `MovementCue` tag rule as the per-life index; cues are rare enough that no live index per remote character is needed.
- **Enum parity:** `tests/specs/MovementStateNames.spec.luau` checks that network.zap's `MovementStateName` enum and `Shared/FSM/MovementStateNames.luau` list the same states.
- **Server guard:** a per-player `MinCueRetriggerSeconds` floor on the same state, matching the client's debounce.
- `Unreliable`: a dropped landing thud is invisible.
- **No distance culling on the server**: engine roll-off (§15.2) handles distance. Add interest management only if a measured bandwidth number calls for it (ARCHITECTURE §9's "don't pad for a cost you haven't measured" spirit).


### 15.6 Constants

`Shared/Constants/PresentationConstants.luau`, one file (like `MovementConstants`), `--!strict`, every polish number (ARCHITECTURE §2). Not in the F4 tuning enum (§15.0).

| Group | Holds |
|---|---|
| Cues | `MinCueRetriggerSeconds`, `DefaultEmitCount`, the `CueAttribute`/`SoundGroupAttribute`/`MountedAttribute` names shared by the mount and the index |
| SFX | `FootstepPitchJitter`, `NearbyRollOffMaxDistance` |
| Camera | `BaseFOV`, `FOVDampingRatio`, `FOVFrequency`, `ShakeProfiles: { [string]: { Magnitude, DurationSeconds } }`, `FOVKickProfiles: { [string]: { Amount, DurationSeconds } }` |
| Shift lock | `ShiftLockOffset`, `ShiftLockDampingRatio`, `ShiftLockIn/OutFrequency`, `ShiftLockMouseIcon`, `FirstPersonHeadTransparency`, `FirstPersonHeadDistance` |

All values are starting points, not tuned. Retune from playtests.


### 15.7 Module map

```
src/Shared/Presentation/MovementCues.luau                          the cue table
src/Shared/Presentation/CueDebounce.luau                           one-shot retrigger floor
src/Shared/Constants/PresentationConstants.luau                    every polish number
src/Shared/Util/Spring.luau                                        damped spring

src/Client/State/MovementLife.luau                                 current life, for CameraController
src/Client/Controllers/CameraController.luau                       FOV, shake, shift lock
src/Client/Controllers/Movement/Presentation/SFXController.luau    per life
src/Client/Controllers/Movement/Presentation/VFXController.luau    per life
src/Client/Controllers/Movement/Presentation/CharacterFX.luau      cue name → instances index (§15.2)
src/Client/Controllers/Movement/Presentation/NearbyCuePlayer.luau  plays other players' Nearby cues (§15.5)

src/Server/Services/MovementCueService.luau                        mount FX, broadcast Nearby cues
src/Server/Events/MirrorStateChanged.luau                          server mirror state changes

default.project.json → ReplicatedStorage.Assets.FX.Movement       R6 FX template folders
Assets/FX/*.rbxmx, *.model.json                                    effects and packs (Footsteps.model.json today)

tests/specs/Spring.spec.luau
tests/specs/MovementCues.spec.luau
tests/specs/CueDebounce.spec.luau
tests/specs/MovementStateNames.spec.luau
tests/specs/FootstepPack.spec.luau
```

**Wiring:** `Movement/init.luau` builds `CharacterFX`/`SFXController`/`VFXController` next to `LocomotionAnimator` each life and publishes `MovementLife`; its `Init` preloads the template once and sets the `PlayMovementCue` callback. The validation service fires `MirrorStateChanged` from `TransitionBookkeeping`. `default.project.json` declares the FX template folders, the `SoundService` groups (`Footsteps`, `Loops`, `Impacts`) and `EnableMouseLockOption = false` (§15.4.3).

Not built until a real caller needs it: a pool for effects that aren't attached to a rig (combat clash sparks, projectile impacts at world points). When one arrives: a fixed ring of pre-created, disabled instances, acquired and released, never created/destroyed per effect (ARCHITECTURE §6).

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

---

## Appendix C: Vault reference (Sorcery)

The reference Vault was built from and why Jianghu's differs, kept for the reasoning behind §4.8. C.1 describes Sorcery's vault (from the decompiled client), C.2 lists where Jianghu departs from it, C.3 records the design goal and the decisions made from it. Vault shipped on 2026-09-25; keep §4.8 current, not this appendix.

### C.1 How Sorcery does it

Source: `Sorcery Decomp/src/ReplicatedStorage/Client/Controllers/MovementController.luau`
- `CheckLedge` (line ~1085): detection
- `PromptVault` (~1152): gating
- `GetYLevel` (~1246): ledge height
- `ClimbVault` (~1264): the motion
- `Update` (~1023) and `Space` (~1113): input buffering

`ClientUtil.GetHealth` is in `Sorcery Decomp/src/ReplicatedStorage/Client/ClientUtil.luau`.

**Trust model:** entirely client-side. The server only receives `ClientEffectDirect:Fire("ClimbVault")` so it can play effects. Nothing is validated.

#### C.1.1 Detection (`CheckLedge`)

It casts two forward rays from the root part, each 8 studs long along `Root.CFrame.LookVector`, and only hits parts in `workspace.Map`:

```
              clearance ray (+8) ─────────────────────▶   must MISS
                                            ┌──────────── ledge top
   root ●                                   │
          wall ray (−1) ───────────────────▶│ Pos, Norm   must HIT
                                            │
   ◀──────────────── 8 studs ──────────────▶
```

| Check | Rule |
|---|---|
| Wall ray | Origin `Root.Position − (0, 1, 0)`, direction `LookVector × 8`. Must hit. Gives `Wall, Pos, Norm` |
| Clearance ray | Origin `Root.Position + (0, 8, 0)`, same direction. Must **miss**: the wall ends below +8, so there's a top to get over |
| Surface | Rejected if `Norm · Y > 0.25`. Floors and gentle slopes don't count; vertical and overhanging walls do |

There's no facing check beyond "the ray goes where the root faces", and no check that the top of the ledge is standable.

**Vault vs climb.** Sorcery's wall climb (`CheckWall`) uses the same wall ray, but the ray at **+12 must hit** (the wall is tall) and a ray **8 studs straight down must miss** (you're well off the ground). A short wall with open space above is a vault; a tall wall is a climb. On Space, climb is tried first, then vault, then double jump.

#### C.1.2 Gating and buffering (`PromptVault`, `Update`, `Space`)

| Gate | Value |
|---|---|
| Airborne only | `Humanoid.FloorMaterial == Air` |
| Cooldown | 0.5 s since the last vault (`LastVault`) |
| Action gate | `ActionCheck.DodgeCheck` (stunned, attacking, etc.). Checked again after the wind-up, so being hit mid-vault cancels it |

**Buffer (auto-vault).** Pressing Space in the air, a slide jump and a climb jump all set `Variables.CanVault = tick()`. `Update` then calls `PromptVault()` **every frame for 1 s**. If you reach a ledge within a second of jumping, you vault without pressing again. The buffer is cleared once you've been on the ground for more than 0.25 s since the press.

**Lockouts it creates:**
- A `No Double Jump` tag for 0.25 s.
- `DoubleJump` returns early if a vault happened in the last 0.1 s. This stops the same Space press from triggering both.

#### C.1.3 Motion (`ClimbVault`)

**Step 0: momentum snapshot** (taken before any movers are cleared):
```
Momentum = Velocity × (0.4, 0, 0.4)       -- keep 40% of horizontal speed
         + (0, |Velocity.Y| / 3, 0)       -- absolute value: a fast fall gives MORE lift
```

**Step 1: wind-up, 0.05 s.**
- `Freeze` + `No Rotate` tags. The Climb animation plays with its speed set to 0, so it holds the first frame.
- A `BodyPosition` (P 25000, D 500, MaxForce 80000) pulls the root toward:
  - **XZ:** `Pos − Norm × 1.25`, 1.25 studs past the wall face, over the top
  - **Y:** `GetYLevel()` (below)
- A `BodyGyro` turns you to face into the wall: `CFrame.lookAt(Root, Root − Norm)`.

`GetYLevel()` estimates the ledge height with two more forward rays (8 studs):
```
Y = Root.Y + 3
if ray at +4 hits: Y = Root.Y + 6
if ray at +6 hits: Y = Root.Y + 8
```
It finds the height in three fixed steps and never looks at where the top surface actually is.

**Step 2: launch, 0.1 s.**
- Re-run the action gate; abort if it fails.
- Snap facing to the camera's horizontal direction: `lookAt(Root, Root + camLook × (1, 0, 1))`.
- A `BodyVelocity` (MaxForce 80000 on every axis) for 0.1 s:
```
V = look × (15 × H) + (0, 35 × H, 0) + Momentum
```
- The Climb animation continues at 1.6× and stops 0.25 s later.
- The FOV jumps by 20 and tweens back to 0 over 0.5 s (Quad).

**`H` (health scaling):** `clamp(Health × 3 / MaxHealth, 0.25, 1)`. Above 33% HP the launch is full; below that it scales down linearly, never under 25%.

#### C.1.4 All the numbers

| Name | Value | Where |
|---|---|---|
| Ray reach | 8 | wall, clearance, height probes |
| Wall ray height | −1 | relative to the root |
| Clearance ray height | +8 | must miss |
| Max normal up-dot | 0.25 | surface filter |
| Over-the-top inset | 1.25 | `Pos − Norm × 1.25` |
| Height steps | +3 / +6 / +8 | probes at +4 / +6 |
| Cooldown | 0.5 s | `LastVault` |
| Buffer window | 1 s | `CanVault` |
| Buffer clear | grounded > 0.25 s | `Update` |
| No-double-jump tag | 0.25 s | |
| Wind-up | 0.05 s | BodyPosition P 25000 / D 500 |
| Launch hold | 0.1 s | BodyVelocity |
| Forward launch | 15 | × H |
| Upward launch | 35 | × H |
| Horizontal momentum kept | 40% | |
| Vertical momentum kept | abs(vy) / 3 | |
| FOV kick | +20 → 0 over 0.5 s | |
| Climb anim speed | 0, then 1.6 | stops after 0.25 s |

#### C.1.5 What not to copy as-is

- **`|vy| / 3` has no upper bound.** A long fall into a ledge launches you higher. That's unbounded vertical gain, and our server's ceiling can't allow it. We keep the term but cap it (C.3).
- **8-stud reach.** The pull can snap you up to 8 studs toward a wall in 0.05 s, which looks like teleporting and is much longer than our cling cast (3 studs).
- **Three-step height guess.** It overshoots low ledges and can put you inside geometry.
- **No standability check.** It will vault onto a sloped roof or a 0.2-stud-thick rail.
- **Deprecated APIs.** `FindPartOnRayWithWhitelist`, `BodyPosition`, `BodyGyro`, `BodyVelocity`.

We copy the camera-steered launch. We don't copy the auto-vault buffer or the health scaling; both were designer decisions (C.3).


### C.2 How Jianghu differs

How Vault works now is in §4.8 (the move) and §8.2-§8.4 (server validation). This lists where it departed from Sorcery as shipped on 2026-09-25; C.3 gives the reasons. Values here are as shipped then (the launch has since been retuned to 70 forward / 50 up and the state to 0.4 s; current numbers are in §4.8).

| | Sorcery | Jianghu |
|---|---|---|
| Trust | Client only; the server plays effects | Claimed (`ClaimTraversalMove "Vault"`), re-probed and bounded by the server |
| Reach | 8 studs | 3 (`VaultReach`) |
| Height window | Wall at root −1, clear at root +8 | Top 1.5 to 6 above the feet |
| Ledge height | Three-step guess (+3 / +6 / +8) | Measured by a downward top probe |
| Standable top | Not checked | Normal Y ≥ 0.7, 1.5 studs deep, 5 studs of headroom (leg footprint) |
| Onto the ledge | 0.05 s `BodyPosition` pull | A mantle of up to 0.2 s (faster if you're rising faster): up the wall face, then across onto the top |
| Launch | `BodyVelocity` held 0.1 s | One-shot velocity writes when the mantle ends; the whole state lasts 0.32 s (the clip's length) |
| Launch direction | Camera | Camera (unchecked by the server; magnitude bounded) |
| Fall-speed lift | abs(vy) / 3, unbounded | abs(vy) / 3, capped at 20 |
| Health scaling | `clamp(3·HP/MaxHP, 0.25, 1)` | None |
| Trigger | Space, plus a 1 s auto-vault buffer | Space; automatic during WallBoost |
| From | Airborne (any state with `FloorMaterial == Air`) | Airborne, DoubleJump, WallCling, WallBoost; not WallRun |
| Vault vs climb | Climb first, then vault | Vault first, then cling |
| Double jump after | Blocked 0.25 s | Blocked 0.25 s; not spent |
| FOV | +20 kick, tweened back over 0.5 s | +10 kick eased back over 0.5 s, on top of the take-off FOV (`FOVKick` cue) |


### C.3 Decisions

#### Design goal

Vault is a **mantle assist**, not a climb. If you're almost over an edge but not quite (your jump came up a little short and the lip is around your chest or head), the vault puts you on top. It is not for scaling tall walls from a distance; WallCling and WallBoost do that. Every decision below follows from this.

#### Decided by the designer (2026-09-25)

| Topic | Decision | Consequence |
|---|---|---|
| Launch direction | **Camera-steered**, as in Sorcery | Read at launch. The server bounds the magnitude only |
| Auto-vault buffer | **No buffer.** Space in the air or while clinging; **automatic during WallBoost** (revised later on 2026-09-25) | The designer wants cling → boost → carried over the lip as one sequence. Automatic stays scoped to the boost: from Airborne/DoubleJump it would snap you onto every low box you jump beside. Sorcery's 1 s post-press buffer isn't copied |
| Fall-speed bonus | **Keep abs(vy) / 3, capped** at `VaultMaxMomentumUpward` | Gives `VaultMaxRise` a finite bound |
| Health scaling | **No, deferred** | `Humanoid.Health` is a fixed rig-compatibility shell (`ARCHITECTURE.md` §12) and no real HP system exists yet. Revisit once real HP, or a Qinggong resource, exists |
| Getting onto the ledge | **Keep the 1.5-6 window.** First a one-frame snap covered by the animation; **revised the same day to a 0.2 s mantle** after a playtest ("you just snap") | The lip is meant to be at chest or head height, so the window stays. Lifting up to 6 studs in one frame read as a teleport no matter the animation |

#### Decided from the goal (2026-09-25)

| Topic | Decision | Why |
|---|---|---|
| Reach | **3 studs** (Sorcery: 8) | "Almost over" means you're already at the wall. Matches `WallClingDistance`. The mantle moves you at most reach + inset (4.25 studs) sideways |
| Height window | Ledge top **1.5 to 6 studs above the feet** (knee to just above the head) | Below knee height you clear it or step up anyway; above head height you're not almost over, so it's a cling |
| Ledge height | **Measured** with a downward top probe | The feet land exactly on the top; no overshoot or clipping |
| Standable top | **Required:** top normal Y ≥ 0.7, 1.5 studs of depth, 5 studs of headroom | The assist should only fire where you can actually stand. No vaulting onto rails, steep roofs or under ceilings |
| Vault vs WallCling | **Vault first** when a standable top is in the window, cling otherwise | They separate cleanly on the clearance cast |
| From DoubleJump | **Allowed** | Double jumping toward a ledge and coming up short is the main use case |
| From WallCling | **Allowed, on Space** (Space did nothing while clinging) | Hanging just under a lip and pressing Space to pull up is the same "almost over" case |
| From WallBoost | **Allowed, automatically** (Space works too) | A boost that runs up past the lip is exactly the case Vault exists for. How high it still reaches, before the boost's separation push carries you out of the 3-stud reach, needs a playtest |
| From WallRun | **Not allowed** | Wall runs are along side walls; a ledge ahead is a different wall. Leap off, then vault from Airborne |
| Spends the double jump? | **No**, matching WallCling. Keeps Sorcery's 0.25 s double-jump block | A vault is recovery, not an extra jump; the block stops a quick second press from double jumping over the launch |
| Launch strength | **Sorcery's 15 forward / 35 up** as starting points; fall-speed lift capped at 20 | 35 up is about 3 studs of rise: enough to clear the lip, not to gain real height. 35 + 20 = 55, the same as a jump |

#### Decided while building (2026-09-25)

Found by checking the plan against the code, before and during implementation.

| Topic | Decision | Why |
|---|---|---|
| Wind-up | **None:** the mantle is the travel time, and the launch fires the moment it ends | Sorcery's 0.05 s only existed as travel time for its `BodyPosition`. A pause on the ledge would make `Update`'s grounded check resolve a landing before the launch fired |
| Mantle motion | **Up the wall face, then across, at one constant speed; each frame aims for where the path will be at the end of that frame** (`TraversalMath.VaultMantlePoint`). **At most 0.2 s, less when already rising faster** (`VaultMantleDuration`), so a fast boost carries over the lip at its own speed rather than braking to about 55 st/s | First built as a one-time `PivotTo` snap, which a playtest found too abrupt. Tracking a timed path arrives exactly on time; a velocity recomputed every tick as (target − position) / T would be exponential decay and never arrive (about 63% at T). Rising before crossing keeps the body off the lip's corner |
| Mantle clearance | **Feet 0.5 above the top** before crossing | Clears the lip, and keeps the Humanoid from reading the top as floor mid-mantle |
| Leaving Vault | **Always to Airborne at the end of the window; no landing checks before it; never into Run/Sprint** (no topology edges, `preAirborneLocomotion` cleared on entry, landings resolved without resume) | Playtest: a landing read in the frame of the launch (still taken from before it) resolved to a resumed Run, and a double-tap W could start Run mid-vault; the Run animation broke the flow. A vault is a recovery; you come out walking. **Reversed 2026-09-28:** a vault now keeps your sprint (§4.8) |
| Launch shape | **One-shot velocity writes** | A constraint followed by a synchronous hand-off would be cleared by `Exit` before physics integrates it, the trap `WallLeapState` documents |
| Server rise bound | **`VaultMaxRise` = `VaultMaxLedgeHeight` + `VaultMantleClearance` + ballistic rise at the momentum cap**, apex one mantle later | The mantle lifts you before the launch; leaving it out would correct most vaults onto 3-6 stud ledges |
| Anchor on the ledge | **For one claim lag plus one mantle after an accept, a ground anchor allows the vault's launch speed** | The mantle ends with the feet over ground the support probe sees, which re-anchors the ceiling to "here plus one jump" and would drop the accept's raise |
| Server ledge probe | **Current root, then the root history over one claim lag** | The mantle moves the replicated root onto the ledge, where no wall is in front of it. Probing where the root was a moment earlier finds the ledge again; each candidate is a real position and runs the full probe. The facing check reads the probe's own cast direction for the same reason |
| Probe cadence | **Server: claim time and buffered retries only.** Client: on the press, and during WallBoost on a throttle derived from the rise speed (`VaultAutoProbeInterval`) | A vault has no sustain check, so the server never needs to poll. A boost at 120 st/s crosses the 4.5-stud window in about 0.04 s, so a fixed 0.1 s throttle would miss it |
| Horizontal bound | **15 + 40% of the server's cap before the vault**, raising the airborne allowance only if that exceeds the cap | Tighter than assuming the WallLeap allowance; never binds at shipped tuning |
| Mantle and the speed check | **An exact displacement credit** of reach + inset, for windows starting within one claim lag plus one mantle of the accept | The leg across is faster than the cap for a short mantle. From a cling (cap 0) the window's budget can't absorb it |
| Cooldown clock | **Server accept time, backdated by time buffered** | Same as the cling clock; brings the server's cooldown clock as close to the client's as it can see |
| Headroom | **The leg footprint swept up**, not one ray | A single ray passes beside a pillar the body would overlap |
| Depth tolerance | **Named constant** `VaultTopDepthTolerance` | `ARCHITECTURE.md` §2: no magic numbers |
| FOV kick | **+10 over 0.5 s**, a new one-shot `FOVKick` cue field added on top of the held take-off FOV (§15.4.2) | A `TargetFOV` on Vault would have stayed raised through Airborne (`HoldsFOV`) until landing. Smaller than Sorcery's +20 because sprint and wall-run FOV are already raised |
