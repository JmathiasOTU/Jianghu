# Jianghu movement system: full audit

Repo `JmathiasOTU/Murim-Ascent-Rework-`, branch `claude/funny-cori-c2uwkl`, head `7b2adab` ("Expand wall traversal mechanics"). Read-only audit; no code was changed.

**Scope read in full:** every file listed in the task (client Movement controllers + 15 states + presentation, `DebugOverlayController`, `ClientBootstrap`, shared FSM/Movement/Constants/Util, server services/state/events/bootstrap, `network.zap`, `Movement.model.json`, and `MovementDebugOverlay.model.json` by structured parse and targeted queries rather than line-by-line, since it is 17.8k lines of Studio export).
**Mechanical checks run:** `stylua --check src` (clean), scripted 46-key tuning parity across 8 sites (clean), greps for `tick`/`wait`/`Instance.new`/`RemoteFunction`/`DataStoreService`/`Died`/`CollisionGroupSetCollidable`/`:: any`/numeric literals. **`selene` was not run** (not installable in this sandbox).
**Citation convention:** `ARCH §n` = `docs/ARCHITECTURE.md`; `CONTRIB` = `CONTRIBUTING.md` non-negotiables; `CLAUDE` = `docs/CLAUDE.md`. "Server" line numbers are `src/Server/Services/MovementValidationService.luau` (abbreviated **MVS**) unless a path is given. "Client init" is `src/Client/Controllers/Movement/init.luau`.

---

## 1. Executive summary

1. **The server's anti-cheat has no vertical axis at all** (M-001): fly, super-jump and gravity hacks are invisible. `enforceSpeedSanity` measures X/Z only; the one Y check runs only inside `DoubleJump`.
2. **The horizontal speed check can be starved indefinitely** (M-002): every FSM transition resets its baseline without auditing the window it discards, and transitions are driven by client-owned Humanoid state. A client that toggles Humanoid state faster than every 0.5 s is never measured.
3. **WallLeap grants a speed allowance derived from the client's own velocity** (M-003) that lasts until the mirror "lands" (which the client also controls). Arbitrary horizontal speed after one accepted leap.
4. **Two reproducible stuck-state bugs**: WallRun has no `HardLanding` edge, so a landing with fall height ≥120 studs while wall-running strands both client and server in WallRun (M-005); a rate-limited `CrouchUp` claim is never re-sent, leaving the server mirror crouched at cap 9 vs the client's 18-40 (M-006).
5. **The rule "no band-aid tolerances" (ARCH §9) is broken by the codebase's own admission** for `SpeedToleranceMultiplier`, `TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE` and `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE`, and nothing ever acts on a violation beyond a snap-back (M-007, M-008, M-017).

Known issues: 3 confirmed, **2 refuted** (WallBoost `AnimationId` is authored; `stylua` is clean). See §2.4.

---

## 2. Tables

### 2.1 State × state transition table (from `StateRules.Transitions`, `StateRules.luau:34-204`)

`●` = legal edge and the target has a `CanEnter` predicate. `○` = legal edge, topology only (only `WallLeap` has no predicate). Blank = illegal.

| from \ to | Idle | Walk | Run | Sprint | CrouchIdle | CrouchWalk | Slide | SlideJump | Airborne | DoubleJump | HardLanding | WallRun | WallLeap | WallCling | WallBoost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Idle** |  | ● | ● |  | ● |  |  |  | ● |  |  |  |  |  |  |
| **Walk** | ● |  | ● |  | ● |  |  |  | ● |  |  |  |  |  |  |
| **Run** | ● | ● |  | ● |  |  | ● |  | ● |  |  |  |  |  |  |
| **Sprint** | ● |  | ● |  |  |  | ● |  | ● |  |  |  |  |  |  |
| **CrouchIdle** | ● | ● |  |  |  | ● |  |  | ● |  |  |  |  |  |  |
| **CrouchWalk** | ● | ● |  |  | ● |  |  |  | ● |  |  |  |  |  |  |
| **Slide** |  |  |  |  | ● | ● |  | ● | ● |  |  |  |  |  |  |
| **SlideJump** |  |  |  |  |  |  |  |  | ● |  |  |  |  |  |  |
| **Airborne** | ● | ● | ● | ● | ● | ● |  |  |  | ● | ● | ● |  | ● |  |
| **DoubleJump** | ● | ● | ● | ● | ● | ● |  |  | ● |  | ● |  |  |  |  |
| **HardLanding** | ● | ● | ● | ● | ● | ● |  |  | ● |  |  |  |  |  |  |
| **WallRun** | ● | ● | ● | ● | ● | ● |  |  | ● |  | **✗ missing** |  | ○ |  |  |
| **WallLeap** |  |  |  |  |  |  |  |  | ● |  |  |  |  |  |  |
| **WallCling** | ● | ● | ● | ● | ● | ● |  |  | ● |  | ● |  |  |  | ● |
| **WallBoost** | ● | ● | ● | ● | ● | ● |  |  | ● |  | ● |  |  |  |  |

Self-transitions are rejected by `StateMachine:CanTransition` (`StateMachine.luau:37-39`).

Table findings:
- **All 15 states are reachable from Idle and every state has at least one exit edge.** No topological dead end.
- **WallRun → HardLanding is missing**, while `LandingResolution.Resolve` (`LandingResolution.luau:81-86`) can return HardLanding to a WallRun caller on both sides. The other three airborne-family states that call `Resolve` (DoubleJump, WallCling, WallBoost) all carry the edge. That asymmetry is the bug in **M-005**.
- WallLeap and SlideJump are one-tick states that re-enter the FSM synchronously (reentrancy traced in §2.3 and **M-019**).
- `DoubleJump → WallRun/WallCling` is absent by design; the claim-buffer logic does not account for it (**M-009**).
- `Airborne` has no edge to `Slide`, `SlideJump`, `WallLeap`, `WallBoost`: correct, each is gated behind its own parent state.

### 2.2 Client ↔ server parity table

"Trust" = what the server reads to decide. **Bold** = client-writable input the server treats as ground truth.

| State | Client entry | Server entry | Client exit | Server exit | Parity / desync notes |
|---|---|---|---|---|---|
| Idle / Walk | keys → `moveIntent.direction` (keyboard only) | **`Humanoid.MoveDirection`** (MVS:391, 779-785) | grounded + input | same | Device-dependent: gamepad/touch never produce client intent (**M-013**). Stuck keys (**M-012**). |
| Run | double-tap W → claim `Run` | claim, then `RequestTransition` (MVS:1816-1861); `runEnteredAt` backdated ≤ half ping | not grounded / no input | passive mirror | Claim resync 1 s (Client init:691-694). |
| Sprint | dwell 3 s → claim `Sprint` | server dwell from its own `runEnteredAt` + buffered retry (MVS:1593-1621) | backpedal / strafe | passive; demotion gated on **`Humanoid.AutoRotate`** (MVS:786-830) | AutoRotate replication is unverified (**M-020**). |
| CrouchIdle / CrouchWalk | Ctrl toggle → claim `CrouchDown/Up` | `crouchHeld` flag only (MVS:1804-1814) | Ctrl toggle | passive | **CrouchUp is fire-once and rate-limited** (**M-006**). Input state survives respawn (**M-012**). |
| Slide | from Run/Sprint + crouch | passive from `crouchHeld` | real decay to CrouchSpeed | nominal decay estimate (MVS:705-733) | Different decay clocks; bridged by landing grace, not a tolerance. Speed cap is a flat ceiling. |
| SlideJump | jump in Slide → sync Airborne | **`Humanoid` Jumping state** (MVS:463-471) → sync Airborne | one tick | one tick | Client leaves group `Crouched` (stale `Apply`, **M-019**), server ends `Default`. |
| Airborne | not grounded | **`Humanoid:GetState()`** (MVS:329-333, 693-703) | grounded | grounded | Whole airborne/grounded split is client-owned (**M-004**). |
| DoubleJump | Space in air, `doubleJumpUsed` clear | claim → `CanEnter` (`not grounded and not doubleJumpUsed`) | 0.45 s or land | 0.45 s from **server accept time** (MVS:519-521) | Server exits later than client by ≥ one-way latency (**M-009**). Reset is on **spoofable** landing (MVS:482). |
| HardLanding | `fallHeight ≥ 120` via shared `Resolve` | same, off server `peakHeight` (client-owned Y) | lock timer | passive; **exits to Airborne on any not-grounded** (MVS:682-685) | **Lock is client-only** (**M-010**). |
| WallRun | Space near wall (client cast) | claim; server re-casts from **replicated CFrame/velocity**; sustain check every Heartbeat (MVS:537-605) | wall lost / 35° / 3 s / land | same + land | **No HardLanding edge** (**M-005**). `wallLeapAllowedSpeed` trusts velocity (**M-003**). |
| WallLeap | Space in WallRun | claim; topology only, no predicate/cooldown (**M-037**) | one tick | one tick | Cap raised until "landing" (MVS:1491-1493, 1211). |
| WallCling | Space, head-on wall | claim; server head-on blockcast; 2.5 s cap; wall-presence recheck 0.1 s (MVS:623-647) | drop / timeout / wall lost / boost / land | same | Cap is exact 0 (**M-016**). Only the Timeout lockout is server-owned (**M-038**). |
| WallBoost | `F` in WallCling | claim from WallCling; `wallBoostStartedAt` | 0.6 s / land | 0.6 s / land | Envelope uses `TraversalMath.WallBoostSpeedCeilingAt` (good), but folds vertical speed into a horizontal budget (**M-024**). |

### 2.3 Edge-case scenario matrix (task area E; traces are in the linked findings)

| # | Scenario | Result | Ref |
|---|---|---|---|
| 1 | Death in each state | Client FSM and server session keep running on the dead Humanoid until `CharacterRemoving`/next spawn (no `Died`/`Dead` handling anywhere). WallRun/WallCling/DoubleJump keep a full-force `LinearVelocity` driving the corpse; server keeps accepting claims and snap-backs. Slide exits (grounded false). `CharacterMover:Destroy` correctly releases the jump-block. | M-011 |
| 2 | `CharacterRemoving` mid-transition | Handlers are synchronous so no torn transition. Module-scope state in 8 state files is not cleared. If removal lands while `setupCharacter` is still in `WaitForChild`, the later `lifeTrove:Add` calls go to an already-destroyed trove and leak the `Heartbeat` connection. | M-022, M-011 |
| 3 | Window focus loss | No `WindowFocusReleased`/`InputEnded` recovery: held W/A/S/D stay latched; `_jumpHeld` stays true, suppressing all future `JumpRequested` (DoubleJump, WallLeap, WallCling) until Space is pressed and released again. | M-012 |
| 4 | Chat / TextBox / `gameProcessedEvent` | `InputBegan` is gated (good), `InputEnded` correctly is not. Residual: W held then chat focused leaves `_forward` latched while Roblox zeroes movement, so client says Walk, server says Idle. | M-012 |
| 5 | Noclip / teleport mid-state | Server teleport resets the speed baseline but not FSM/`peakHeight`/overrides: a downward teleport mid-air inflates `fallHeight` on both sides and forces HardLanding. Noclip-off sets `CanCollide = true` on every part, including accessories. Dev-only. | M-029 |
| 6 | Tuning change mid-state | Server cap changes immediately on `RequestSetTuning`; client `WalkSpeed` only updates on the next state `Enter`. Transient rubber-band for developers. | M-032 |
| 7 | Shift Lock toggle | `FacingController` rewrites `AutoRotate` every RenderStepped; the server samples it with lag (and possibly never sees it). A landing resolved at the toggle instant can pick different tiers client/server. | M-020 |
| 8 | 1-3 s server lag | Traversal claims are fire-once (no resync) and their 0.25 s buffer starts at arrival. A delayed WallLeap is rejected; the client then flies at ~133 studs/s against a 52 studs/s cap. Bursty replication on recovery false-flags legitimate movement. | M-015 |
| 9 | Double-press on the exact frame | `_jumpHeld` edge guard + topology make a same-frame second press a no-op (DoubleJump → WallCling/WallRun is absent on both sides). No defect found beyond the buffer-drop race. | M-009 |
| 10 | Landing on a player's head / moving floors | Characters collide (no collision rules exist). Standing on any moving surface (platform, vehicle, another player) adds floor velocity to the world-space displacement that `enforceSpeedSanity` caps. | M-014, M-018 |
| 11 | StreamingEnabled | Server always has full geometry; a client with unstreamed walls only under-predicts (safe direction). Decision is undocumented. | M-034 |
| 12 | Input-device switching | Movement intent, jump, crouch and boost are all keyboard `KeyCode` checks; gamepad/touch have no intent at all. | M-013 |

### 2.4 Known issues: verdicts

| Known issue | Verdict | Evidence |
|---|---|---|
| Server HardLanding lets the player go Airborne whenever not grounded; verify the `SetJumpBlocked` fix has no side effects | **Confirmed** (server side). Client-side `SetJumpBlocked` fix reviewed: **no functional side effects found**, listed limits in M-010. | MVS:682-685; `CharacterMover.luau:296-310`; `Client init:376,392` |
| No combat FSM | **Confirmed.** No Stagger/Posture/Defeated state exists; `qinggong = math.huge` placeholder (MVS:434). | `MovementStates.luau`, `StateRules.luau:328-339` comment |
| No lag-compensation / pose-history utility | **Confirmed.** Only `GetNetworkPing()`-based dwell backdate (MVS:1834-1843). | `Shared/Util` contains only `RateLimiter`, `ViolationTracker` |
| WallBoost `AnimationId` blank | **Refuted at this commit.** `Movement.model.json` has all 27 slots authored; WallBoost = `rbxassetid://136022644832167`. The `LocomotionAnimator` blank-ID warning path is still there. | `Assets/Animations/Movement.model.json` (parsed) |
| `stylua`/`selene` never ran clean | **`stylua`: refuted** (`stylua --check src` exit 0). **`selene`: unknown**; not runnable here. | command output |

---

## 3. Findings (severity order)

### CRITICAL

#### M-001: Vertical axis is completely unpoliced
- **Severity:** Critical | **Category:** Security | **Confidence:** Confirmed
- **Location:** MVS:1269-1271 (comment "Vertical (Y) motion is deliberately excluded"), 1303 (`flatDelta` zeroes Y), 1333 (correction keeps `position.Y`), 1401-1433 (only Y check, DoubleJump only)
- **What's wrong:** `enforceSpeedSanity` compares X/Z only and never restores Y. `enforceDoubleJumpTrajectory` is the sole vertical check and runs only while the mirror is in `DoubleJump` (0.45 s), with an upper-bound-only tolerance of 15 studs/s.
- **Trace (server Heartbeat, after replication receive/physics):** exploiter client writes `rootPart.AssemblyLinearVelocity = (0, 50, 0)` (or steps `CFrame.Y`) every frame → server Heartbeat: `updatePeakHeight` (Y grows, harmless) → `mirrorPassiveTransitions` (Humanoid state unchanged) → `enforceSpeedSanity`: `flatDelta.Magnitude = 0` ≤ `maxDistance` → no violation, no correction → `enforceDoubleJumpTrajectory` returns (state ≠ DoubleJump).
- **Impact:** fly, arbitrary jump height, zero-gravity, vertical teleport (escape the map, skip wall/ledge content). Bypasses every traversal cost (double jump, wall boost, stamina later).
- **Rule:** ARCH §3 (client is a liar; sanity checks on spatial claims), §9 (fix the cause).
- **Fix direction:** add a vertical envelope validated over the same sample window: allowed rise = ballistic apex from the *currently legitimate* impulses (Humanoid jump from `JumpPower`, DoubleJump/WallLeap/WallBoost via the existing `TraversalMath` functions and `Workspace.Gravity`), only credited when the server has confirmed the corresponding claim; sustained upward velocity outside those windows or hovering (Y-velocity ≈ 0 with no ground under `SpatialQueries.QueryGround`) is a violation. Correct Y as well as X/Z.

#### M-002: Baseline reset on every FSM transition lets a client starve the speed check
- **Severity:** Critical | **Category:** Security | **Confidence:** Confirmed
- **Location:** MVS:1177-1180 (`fsm.changed` handler in `createSession`), 1297-1299 (`elapsed < SpeedCheckIntervalSeconds → return`); also 1446-1447, 1458-1460, 1469-1470, 1688-1689, 1706-1707, 1946-1947
- **What's wrong:** the handler sets `speedCheckPosition = rootPart.Position; speedCheckAt = now` on *every* transition. The window being discarded is never evaluated. Transitions in the server mirror are passive and follow `Humanoid:GetState()`, which the client owns.
- **Trace:** t=0 exploiter moves at 300 studs/s. t=0.05 `Humanoid:ChangeState(Freefall)` → Heartbeat: Idle→Airborne fires `changed` → baseline := now. t=0.10 `ChangeState(Running)` → Heartbeat: Airborne→Idle/Walk → baseline := now. Repeat at ≥2 Hz. Every `enforceSpeedSanity` call hits line 1297 with `elapsed < 0.5` and returns; line 1308 is never reached. Passive transitions are not covered by either rate limiter.
- **Impact:** unlimited horizontal speed and teleport at zero detection cost, using only client-side Humanoid calls.
- **Rule:** ARCH §3, §9 (the reset is justified as sidestepping a tolerance, but it discards evidence instead).
- **Fix direction:** never discard an unaudited window. At each boundary, evaluate the closing window against `max(cap_old, cap_new) × elapsed` (that is the documented residual-momentum case and needs no tolerance constant), or replace the 0.5 s sampling with a per-Heartbeat budget accumulator (`budget += cap(state, now) × dt`; consume by measured displacement; violation when consumption exceeds budget over a rolling window). Also rate-limit passive mirror transitions per session.

#### M-003: WallLeap speed allowance is derived from client-owned velocity and persists until a spoofable "landing"
- **Severity:** Critical | **Category:** Security | **Confidence:** Confirmed
- **Location:** MVS:1491-1493 (`wallLeapAllowedSpeed = context.horizontalVelocity.Magnitude + burst + push`), 413-417 (velocity read from `AssemblyLinearVelocity`), 1074-1076 (cap raised), 1204-1211 (cleared only on `GROUNDED_STATES`)
- **What's wrong:** the allowance is `v_now + 75 + 75` where `v_now` is the replicated velocity the client wrote. It has no expiry other than the mirror entering a grounded state, which the client also decides (M-004). Nothing bounds `v_now`.
- **Trace:** exploiter legitimately wall-runs (server WallRun accepted, legit speed 35) → for one frame sets `AssemblyLinearVelocity` horizontal = 5000 → sends `WallLeap` claim → server `buildContext` reads 5000 → `RequestTransition(WallLeap)` accepted (topology only) → `wallLeapAllowedSpeed = 5150`. `effectiveMaxSpeed` returns 5150 until the mirror lands; the exploiter simply never reports a grounded Humanoid state. Cap becomes 5150 × 1.3 studs/s.
- **Impact:** effectively uncapped horizontal speed for the rest of the airtime, from one wall.
- **Rule:** ARCH §3 ("never trusts a client-claimed value"), §9.
- **Fix direction:** WallRun velocity is server-known. Use `constants.WallRunSpeed + WallLeapBurstForce + WallLeapPushForce` (the sum bound the comment already argues for), not the sampled velocity. Expire the allowance by time (ballistic flight time from `WallLeapUpwardForce` and `Workspace.Gravity`) in addition to landing. Gate leaps with a cooldown (M-037).

### HIGH

#### M-004: The server treats client-owned Humanoid/physics state as ground truth
- **Severity:** High | **Category:** Security | **Confidence:** Confirmed
- **Location:** MVS:329-333 (`isGrounded`), 391-405 (`MoveDirection`, `GetState`), 413-417, 440 (`AutoRotate`), 474-489 / 507-517 / 538-543 / 624-629 (grounded gates the `doubleJumpUsed` reset), 693-703
- **What's wrong:** the comment at MVS:341-344 calls `CFrame`/`MoveDirection` "server-trusted replicated state". They are network-owner-written. Consumers: grounded (Airborne/landing/DoubleJump reset), jumping (SlideJump), move intent (Idle/Walk, WallRun entry gate, Sprint demotion), fall height (`peakHeight` from Y), facing (WallCling gate), velocity (M-003).
- **Trace (infinite double jump):** client claims `DoubleJump` (accepted, `doubleJumpUsed = true`) → next frame `Humanoid:ChangeState(Landed)` → Heartbeat mirror: DoubleJump/Airborne + `grounded` → `RequestTransition(Resolve(...))` succeeds → `doubleJumpUsed = false` (MVS:482/509) → next frame `ChangeState(Freefall)` → claim `DoubleJump` again. Limiter allows 5 claims/s = 5 mid-air jumps/s, each unchecked in Y (M-001). The same toggle clears `peakHeight` and thus HardLanding.
- **Impact:** DoubleJump/Wall-move resource resets, HardLanding avoidance, tier spoofing. Combined with M-001/M-002 there is no server-side movement authority left.
- **Rule:** ARCH §3 ("server-side FSM mirroring", "sanity raycasts"), CONTRIB non-negotiable 2.
- **Fix direction:** derive `grounded` on the server from `SpatialQueries.QueryGround` (already shared and used for Slide) plus floor-contact tolerance, and treat `Humanoid:GetState()` as a hint that must agree. Reset `doubleJumpUsed`/`peakHeight` only on ray-confirmed contact, not on a state label.

#### M-005: WallRun has no HardLanding edge; grounded landing with fall height ≥120 strands client and server in WallRun
- **Severity:** High | **Category:** FSM | **Confidence:** Confirmed (code trace; occurrence needs a ≥120 stud excursion)
- **Location:** `StateRules.luau:139-148` (WallRun edges), 176-186 / 194-203 (WallCling/WallBoost include HardLanding); `LandingResolution.luau:81-86`; `WallRunState.luau:146-150`; MVS:538-543
- **Trace (client, Heartbeat):** player falls from a 200-stud tower, presses Space near a wall at ≈10 studs above ground → `RequestTransition(WallRun)` accepted (`fallHeight` already ≈190). Player touches ground within the 3 s duration → `WallRunState.Update`: `context.grounded` → `RequestTransition(AirborneState.ResolveLandingTarget(context))` → `Resolve` returns HardLanding (`fallHeight ≥ 120`) → `CanTransition` fails on topology → `return` (line 150) → repeats every frame. The full-force `LinearVelocity` override (WallRun tangent × 35, sink −6) keeps driving the grounded character along the wall; the duration/wall-lost checks below the early `return` are unreachable.
  **Server:** MVS:538-543: same `Resolve` → rejected → `return` before the duration check → mirror stays WallRun, `doubleJumpUsed`/`peakHeight` never reset, cap stays `WallRunSpeed`.
- **Impact:** uncontrollable slide along the floor until Space (which fires a full WallLeap launch); mirror stays out of sync. The same "Sprint dead end" class the code already fixed once (comment at `StateRules.luau:131-138`).
- **Rule:** ARCH §2 (FSM integrity).
- **Fix direction:** add `HardLanding` to `Transitions[WallRun]` and add a regression test over `Transitions` asserting every airborne-family state that calls `Resolve` includes every value `Resolve` can return. Also let the grounded branch fall through to force-exit if `RequestTransition` fails.

#### M-006: `CrouchUp` is fire-once and shares the 5/s claim limiter; a dropped `CrouchUp` is never repaired
- **Severity:** High | **Category:** Desync | **Confidence:** Confirmed (code); triggers under rapid input
- **Location:** Client init:592-601 (single `Fire("CrouchUp")`), 700-706 (resync fires `CrouchDown` only while held); MVS:265, 1785-1795 (limiter drops silently), 1804-1814
- **Trace:** player taps Ctrl several times in one second while also generating Run/Sprint claims and their 1 s resyncs (each accepted claim shares the same 5-per-second window as `CrouchDown`/`CrouchUp`). The 6th claim in the window is dropped by `TryAcquire`. If it is `CrouchUp`: client is standing, `IsCrouchHeld()` false, so no resync is ever sent. Server keeps `crouchHeld = true` (MVS:1805), `mirrorPassiveTransitions` demotes to CrouchIdle/CrouchWalk, cap `CrouchSpeed` = 9. Client moves at 18-40.
- **Impact:** persistent rubber-banding every 0.5 s until the player toggles Ctrl again. Not self-healing.
- **Rule:** ARCH §3 (mirror must track the client), §5 (limiter must not drop authoritative-state edges without a repair path).
- **Fix direction:** send crouch state as a level, resynced in both directions (`CrouchDown`/`CrouchUp` resend on the same cadence, or a single `SetCrouch(bool)`), and give crouch edges their own limiter budget separate from Run/Sprint.

#### M-007: `SpeedToleranceMultiplier = 1.3` is an unmeasured padding factor, permanently ceding ≥30 % speed
- **Severity:** High | **Category:** Security | **Confidence:** Confirmed
- **Location:** `MovementConstants.luau:19-27` (comment: "Flagged unmeasured … left unchanged rather than guessed"), MVS:1304-1308; live-tunable via `MovementTuning` (M-017 notes the inconsistency)
- **What's wrong:** the value is a generic multiplier on every tier. Effective sustained caps: Sprint/Airborne 52 studs/s (vs 40), Run 36.4 (vs 28), Slide 65, WallRun 45.5 (vs 35). The comment concedes the number is not measured, which is exactly what ARCH §9 forbids.
- **Trace:** exploiter walks at 1.29 × SprintSpeed; each 0.5 s window has `flatDelta ≤ maxDistance`; nothing is flagged, ever.
- **Impact:** persistent, undetectable +30 % speed; scales with any future tier.
- **Rule:** ARCH §9.
- **Fix direction:** capture real replication error with the existing `SPEED_SANITY_DEBUG_LOGGING`, then either fold the measured jitter into the window definition (e.g. compare against interpolated positions) or set the multiplier from the measured 99.9th percentile, with the measurement cited next to the constant. Remove it from the live-tuning surface (M-017).

#### M-008: A violation has no consequence beyond a snap-back
- **Severity:** High | **Category:** Security | **Confidence:** Confirmed
- **Location:** MVS:1312-1336 (record + correct), 1353-1390 (only consumer of `speedViolations:Get` is the dev overlay), `ViolationTracker.luau`
- **What's wrong:** `count`/`history` are recorded but never read by any policy: no threshold, no kick, no telemetry, no decay. Correction rewrites position only (line 1333-1335) and leaves velocity, so a cheater is back at full speed in the next window. `Record` is called only for horizontal speed (M-001 categories add none).
- **Impact:** cheating is free to retry indefinitely; server staff have no signal. ARCH §5 calls for flagging, which does not exist for movement.
- **Rule:** ARCH §5 (anti-exploit tracked and flagged).
- **Fix direction:** consume `ViolationTracker` in the service: windowed threshold → flag/log to a persisted sink → escalate (kick/shadow flag). Zero `AssemblyLinearVelocity` on correction.

### MEDIUM

#### M-009: Buffered WallRun/WallCling claims are dropped while the mirror is still in DoubleJump (the case the buffer was built for)
- **Severity:** Medium | **Category:** Desync | **Confidence:** Plausible
- **Location:** MVS:1527-1540 (WallRun buffer), 1566-1579 (WallCling buffer); `DoubleJumpDecayDurationSeconds = 0.45`; traversal claims are single-shot (Client init:419-435)
- **Trace:** client double-jumps at t=0 (server accepts at t=L; server DoubleJump→Airborne is timed from that accept, MVS:519-521). Client leaves DoubleJump at 0.45 and enters WallRun at ~0.46 → claim arrives at ≈0.46+L. If server elapsed is a few ms short of 0.45 (jitter), `mirrorPassiveTransitions` still shows DoubleJump; `RequestTransition(WallRun)` fails topology; buffer armed; next Heartbeat `retryBufferedTraversalClaims` sees `current ~= Airborne` → `else` branch clears the buffer (line 1538). Claim lost; no resend exists.
- **Impact:** server mirror stays Airborne while client wall-runs. Speed cap 40 vs run at 35: usually invisible; a following WallLeap claim is rejected and the leap is snapped back ("boost erased").
- **Rule:** ARCH §3 (mirror parity), §9 (root cause, not wider buffers).
- **Fix direction:** also retry while `current == DoubleJump` (the passive mirror will move it to Airborne within a Heartbeat), or resend traversal claims on the same 1 s resync cadence used for Run/Sprint.

#### M-010: HardLanding is a client-only lock; server allows Airborne on any not-grounded (known issue, confirmed) and comments contradict the code
- **Severity:** Medium | **Category:** Security / Comment mismatch | **Confidence:** Confirmed
- **Location:** MVS:681-691, 1034-1037 (cap 6, not 0); `HardLandingState.luau:22-25` (claims lock "is authoritative, not just a client-side courtesy … HardLanding -> 0 cap"), 40-44
- **What's wrong:** the lock is `WalkSpeed = 0` + `SetJumpBlocked` on the client. The server can only cap displacement at `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE = 6` (×1.3 × 0.5 s ≈ 3.9 studs per window) and treats any `not grounded` as an exit (line 682-685), so a client that reports `Jumping`/`Freefall` leaves the lock immediately with the tier cap restored.
- **`SetJumpBlocked` side-effect review:** the shared `_jumpBlocked` boolean (CAS guard, line 297) is consistent across hand-offs because `Exit(previous)` runs before `Enter(next)` (Client init:376,392); `CharacterMover:Destroy` releases it (line 375-380) so death mid-lock cannot leak the CAS binding or the disabled Jumping state. `Humanoid.Jump = false` on release discards a buffered press (intended). Remaining limits: the `BindAction` sink relies on equal-priority ordering with the default `CharacterJump` binding; a sunk `CharacterJump` binding should make Space arrive with `gameProcessedEvent = true` (Roblox documents CAS-handled input as processed), which would explain why `JumpRequested` stops firing during Crouch/Cling/Boost (consistent, but implicit and worth a live check); none of it constrains a modified client. No functional regression found.
- **Rule:** ARCH §3.
- **Fix direction:** make HardLanding exit require ground loss confirmed by `QueryGround` (M-004) and enforce a server-side cap of 0 with a measured jitter allowance instead of 6; fix the comments.

#### M-011: No death handling; corpse is driven and the server session outlives the life
- **Severity:** Medium | **Category:** Lifecycle | **Confidence:** Confirmed
- **Location:** Client init:741-746 (only `CharacterRemoving`); MVS:1753-1764, 1766-1773; no `Died`/`Dead` reference anywhere in `src`
- **What's wrong:** between `Humanoid.Died` and `CharacterRemoving` (default 5 s) the FSM keeps updating on a Dead Humanoid (`GetState() == Dead` → not grounded). WallRun (up to 3 s), WallCling (2.5 s) and DoubleJump keep a full-force `LinearVelocity` driving the body. Server keeps accepting claims and applying snap-backs to the corpse until the next `CharacterAdded` overwrites the session.
- **Impact:** corpse flung along walls; server logs/violations recorded against dead bodies; and once combat lands, claims from dead players are accepted.
- **Rule:** ARCH §12 (defeat is not `Died`, but movement still must stop cleanly on defeat), §6.
- **Fix direction:** add an explicit `Defeated`/dead gate to the FSM (both sides) via the future combat state rather than `Humanoid.Died`; until then, tear down the movement life on `HealthChanged`/`Died` for cleanliness (movement only).

#### M-012: Input recovery: stuck keys, latched `_jumpHeld`, crouch toggle survives respawn
- **Severity:** Medium | **Category:** Input | **Confidence:** Confirmed (code); occurrence needs focus loss
- **Location:** `InputController.luau:80-150`; Client init:726-738 (`input = InputController.new()` once in `Init`, shared across lives)
- **What's wrong:** no `WindowFocusReleased`/`GuiService` handling. `_forward/_backward/_strafe*`, `_jumpHeld` and `_crouchHeld` are latched by `InputBegan` and cleared only by a matching `InputEnded`, which is not delivered after alt-tab or when a TextBox takes focus mid-press. `_crouchHeld` is a toggle stored on a controller that outlives the character, so a player who dies while crouched respawns "crouched" (client) with `crouchHeld = false` (server) until the 1 s resync.
- **Trace (latched `_jumpHeld`):** hold Space, alt-tab, release, return → `_jumpHeld = true` → the next Space `InputBegan` returns at line 98-100 → `JumpRequested` never fires again until one Space press/release completes. DoubleJump, WallRun/Leap/Cling entry all depend on it.
- **Fix direction:** on `WindowFocusReleased`, focused-TextBox change and `CharacterAdded`, clear all latched state; give `InputController` a `Reset()` called from `setupCharacter`.

#### M-013: Movement intent, jump, crouch and boost are keyboard-only
- **Severity:** Medium | **Category:** Input | **Confidence:** Confirmed (design status unknown, see §7 Q1)
- **Location:** `InputController.luau:53-57, 87-117, 155-185`
- **What's wrong:** gamepad thumbstick and touch produce no `moveIntent.direction`, so `HasMoveInput` is false, the FSM stays Idle, `CanEnter[WallRun]` (needs `moveIntent.direction.Magnitude ~= 0`) is never true, and Run/Sprint/Crouch/Boost are unreachable. The server derives intent from `Humanoid.MoveDirection` (device-agnostic), so the mirror shows Walk while the client sits in Idle.
- **Fix direction:** if non-keyboard is in scope, read `Humanoid.MoveDirection`/`ControlModule` output for intent and add action-based bindings; otherwise document keyboard-only and gate the loop.

#### M-014: Moving floors, seats and unhandled Humanoid states are treated as speed hacks or as Airborne
- **Severity:** Medium | **Category:** Physics / False flags | **Confidence:** Confirmed
- **Location:** MVS:329-333 (only Running/RunningNoPhysics/Landed are grounded), 1301-1308 (world-space displacement, no floor-velocity term), 693-703
- **What's wrong:** displacement is measured in world space against a state-based cap. Standing on a moving platform, vehicle, or another player's head adds the floor's speed. Every other Humanoid state (`Seated`, `Climbing`, `Swimming`, `PlatformStanding`, `Ragdoll`, `Physics`, `FallingDown`, `GettingUp`) maps to "not grounded → Airborne" with cap `SprintSpeed`. Consequences: DoubleJump is legal while swimming/climbing (`doubleJumpUsed` never resets without a landing); seated vehicles above 52 studs/s are snapped back; combat knockback/ragdoll above 52 studs/s will be snapped back.
- **Fix direction:** subtract `rootPart.AssemblyLinearVelocity` of the standing surface (from the ray hit part) from the measured displacement, exempt `Seated`/ragdoll/knockback windows explicitly through an event (like `CharacterTeleported`), and decide the intended behaviour per Humanoid state (§7 Q9).

#### M-015: Replication bursts after 1-3 s lag produce false positives; traversal claims are never resent
- **Severity:** Medium | **Category:** Desync | **Confidence:** Plausible
- **Location:** MVS:1295-1308, 1722-1735; Client init:419-435
- **Trace:** 2 s network stall → server sees a frozen position, then a burst; the next 0.5 s sample contains ~2 s of legitimate travel with `elapsed ≈ 0.5` → `flatDelta` ≫ cap → snap-back of 2 s of legitimate progress. Claims sent during the stall arrive up to 2 s late: the WallLeap claim is rejected (mirror already landed), the client is mid-flight at ~133 studs/s versus a 52 studs/s cap.
- **Rule:** ARCH §9 (root cause, not a bigger multiplier).
- **Fix direction:** detect replication stalls (no position change across N Heartbeats with a live Humanoid) and credit the stalled interval to the budget; resend traversal claims on the resync cadence so the server can reconcile.

#### M-016: WallCling cap is exactly 0 with a strict `>` compare
- **Severity:** Medium | **Category:** False flags | **Confidence:** Plausible
- **Location:** MVS:1015-1022 (`WallClingSpeedCeiling = 0`), 1308 (`flatDelta.Magnitude > maxDistance`), 1117-1119 (grace only 1 s); `MovementConstants.luau:326, 341, 356` (`WallClingRecheckInterval = 0.1`, `WallClingSpeedCeiling = 0`, `WallClingDropSeparationSpeed = 10`)
- **Trace:** cling lasts ≤ 2.5 s. After the 1 s landing-momentum grace `maxDistance` is exactly 0, so any nonzero horizontal delta (float noise from replication, contact micro-motion, or the 10 studs/s drop push landing before the server's next 0.1 s wall recheck) is a violation and a snap-back.
- **Fix direction:** define "no drift" as position stable within measured replication precision, cite the measurement next to the constant, and make the server mirror exit WallCling on the same event as the client (a Drop claim) instead of waiting for the recheck.

#### M-017: Two more unmeasured tolerances, and the tuning surface is inconsistent about them
- **Severity:** Medium | **Category:** Rule violation (§9) | **Confidence:** Confirmed
- **Location:** MVS:272-284 (`TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE = 15`, "unmeasured … starting point guess"; `HARD_LANDING_RESIDUAL_SPEED_TOLERANCE = 6`, no measurement cited); `MovementTuning.luau` (`SpeedToleranceMultiplier` is live-tunable) vs MVS:1015-1021 (which excludes `WallClingSpeedCeiling` from tuning for the exact reason "a knob a developer can nudge away a false flag with")
- **Impact:** three server tolerances with no cited measurement (with M-007), and the project disagrees with itself about whether they may be tuned.
- **Fix direction:** measure (flags already exist), cite, and take all validation tolerances off the live-tuning surface.

#### M-018: Collision groups are inert (no collidable rules), and characters collide with each other
- **Severity:** Medium | **Category:** Physics | **Confidence:** Confirmed (repo); Studio-side config not visible
- **Location:** `CollisionGroups.luau` (`RegisterGroups` only registers); repo-wide grep finds no `CollisionGroupSetCollidable`; MVS:1234, 1258; Client init:350, 398
- **What's wrong:** `Character` and `CharacterCrouched` are registered but no pair rule is ever set, so both collide with everything by default; the "crouched passability" feature does nothing. `RegisterCollisionGroup` on a group Studio already defines would error, so Studio-side rules are unlikely. Character-vs-character collision therefore stays on: a player landing on another's head stands on them, moves with them (M-014), and can be pushed.
- **Fix direction:** define the rule table in `RegisterGroups` (`CollisionGroupSetCollidable`) and decide player-vs-player collision intent (§7 Q5).

#### M-019: Reentrant SlideJump leaves the client in the wrong collision group while airborne
- **Severity:** Medium (latent until M-018 is fixed) | **Category:** FSM / Reentrancy | **Confidence:** Confirmed
- **Location:** Client init:361-398; `CollisionGroups.luau` (`CROUCHED_STATES` includes SlideJump)
- **Trace:** `RequestTransition(SlideJump)` → `current = SlideJump` → `changed(SlideJump, Slide)` → handler: `Exit(Slide)`, `Enter(SlideJump)` → `SlideJumpState.Enter` calls `RequestTransition(Airborne)` reentrantly → inner handler: `Exit`, `Enter(Airborne)`, `Apply(character, Airborne)` → group `Character` → inner returns → outer handler resumes at line 398 with the stale `next = SlideJump` → `Apply(character, SlideJump)` → group `CharacterCrouched`. `fsm.current` is Airborne, character stays Crouched until the landing transition. Server ends `Character` (its SlideJump→Airborne is two separate `RequestTransition` calls at MVS:464-469), so parity breaks.
- **Reentrancy audit:** WallLeap follows the same shape; there the stale post-`Enter` work is only the `WallLeap` claim (`Fire` at line 425, order-safe) and `lastWallLeapWall`. Bookkeeping (`peakHeight`, `preAirborneLocomotion`) is correct because the inner (Airborne) handler runs it with `previous = SlideJump/WallLeap`.
- **Fix direction:** apply the collision group from `fsm.current` (not the handler arg) at the end of the outermost handler, or defer reentrant hand-offs with `task.defer`.

#### M-020: Server reads properties the client writes locally (`AutoRotate`), and the assumption is unverified
- **Severity:** Medium | **Category:** Parity | **Confidence:** Plausible (needs a live-server check)
- **Location:** MVS:440 (`cameraLocked = not humanoid.AutoRotate`), 786-830 (Sprint demotion gated on it); `FacingController.luau:56-66` (client writes `AutoRotate` every RenderStepped); comment at MVS:809-810 ("a plain replicated Humanoid property")
- **What's wrong:** property writes from a client do not replicate to the server for non-physics properties; `WalkSpeed`, `JumpPower` and `AutoRotate` are documented exploit vectors for exactly this reason. If `AutoRotate` never replicates, `cameraLocked` is constant `false` and the Sprint demotion branch (`... and not AutoRotate and not moveIntent.forward`) is dead code, and the landing-tier playtest "fix" may have worked only because the lenient path is always taken.
- **Verify:** on a live server, print `humanoid.AutoRotate` server-side while toggling Shift Lock on the client. Same check for `MoveDirection`.
- **Fix direction:** if unreplicated, send lock state as an explicit claim (like crouch) instead of inferring it.

#### M-021: Per-Heartbeat allocation pressure on the server
- **Severity:** Medium (scales with players) | **Category:** Performance | **Confidence:** Confirmed
- **Location:** `MovementTuning.luau:244-306` (`WithOverrides` calls `Defaults()`, a fresh 46-field table, every time); `MovementTuningState.luau:40` (`GetEffective`); MVS:1969 (once in the loop) and MVS:385 (once in every `buildContext`), plus `buildContext` allocating a context table, a `moveIntent` table and several `Vector3`s
- **Estimate:** ≥2 `GetEffective` calls per session per Heartbeat (loop + the mirror's `buildContext`) = at 50 players ≈ 6,000 46-field tables/s (~276k table writes/s) plus GC, before retry paths. `humanoid:GetState()` is called ≥4× per session per Heartbeat (`buildContext` reads it twice, plus `updateWallRunQuery` and `updateWallClingQuery`).
- **Cast cost:** WallRun spherecast and WallCling blockcast are throttled to 10 Hz per airborne session (MVS:878-922), each building a fresh `RaycastParams`. Worst case ≈ 1,000 casts/s at 50 all-airborne players; acceptable but avoidable.
- **Fix direction:** cache the effective table per player, invalidated only by `SetOverride/ClearOverride`; pass it through instead of re-fetching; build `buildContext` once per session per Heartbeat; reuse `RaycastParams`.

#### M-022: Module-scope state in client state modules survives the FSM's destruction
- **Severity:** Medium | **Category:** FSM / Leakage | **Confidence:** Confirmed
- **Location:** module-scope locals in `WallClingState.luau:27-40` (`wall`, `normal`, `enteredAt`, `recheckAccumulator`, `boostUsed`, `lockoutUntil`, `pendingExitReason`), `WallRunState.luau:27-37`, `SlideState.luau:31-43`, `RunState.luau:18`, `DoubleJumpState.luau:26`, `WallBoostState.luau:24`, `HardLandingState.luau:32`, `AirborneState.luau:20`
- **Trace:** if the life ends mid-state, `lifeTrove:Destroy()` destroys the FSM without running `Exit`. Stale values persist into the next life: `WallClingState.lockoutUntil` blocks re-cling for up to `WallClingTimeoutLockout` (0.75 s) into the new life (server has none, so it is a client-only desync); `AirborneState.lastLandingWasMedium` drives the wrong landing animation until the next landing.
- **Rule:** ARCH §6 (state owned by the object, destroyed once per life, never reused across a cleanup boundary).
- **Fix direction:** per-context state (`context.stateData[state]`) or a `Reset()` per state invoked on `CharacterAdded`.

#### M-023: Server session lifecycle does not follow ARCH §6
- **Severity:** Medium | **Category:** Lifecycle / Memory | **Confidence:** Confirmed
- **Location:** MVS:1753-1764 (`onCharacterAdded` overwrites `sessions[player]` without destroying the old session/FSM), 1766-1773 (only `PlayerRemoving` calls `fsm:Destroy()`), 1123-1177 (no `Trove` on the session), `DevToolsService.luau:147`, `MovementTuningService.luau` (`player.CharacterAdded:Connect` results not tracked)
- **Impact:** old sessions are only reclaimed by GC; no leak of live signals was found (nothing external references them), but the rule is broken, the old session keeps being iterated by the Heartbeat loop until replaced, and (Plausible) two quick `CharacterAdded` events can leave the session bound to the older character if the first `WaitForChild` pair resolves last.
- **Fix direction:** give `PlayerSession` a `Trove` (FSM, connections, signal) and destroy it on `CharacterRemoving`/replacement.

#### M-038: Two of three WallCling lockouts are client-only (server-owned cooldown rule)
- **Severity:** Medium | **Category:** Security / Parity | **Confidence:** Confirmed
- **Location:** MVS:641-642 (only `WallClingTimeoutLockout` is set), 1703-1707 (WallBoost accept sets `wallClingBoostUsed` and `wallBoostStartedAt`, no lockout), 1461 (`wallClingBoostUsed = false` on every cling accept); client: `WallClingState.luau:178-185` applies Timeout/Dropped/Boosted lockouts
- **Impact:** `WallClingPostBoostCooldown` (0.25 s) and `WallClingDropLockout` (0.3 s) are not enforced by the server, so a cheater can chain Cling → Boost → Airborne → Cling → Boost at the claim rate limit (5/s) for an unbounded climb (moot until M-001 is fixed, but a cooldown-parity bug on its own).
- **Rule:** ARCH §3 ("server-owned cooldowns").
- **Fix direction:** apply all three lockouts to `session.wallClingLockoutUntil` server-side, with the exit reason derived from the mirror's own transition.

### LOW / NIT

- **M-024: WallBoost ceiling mixes vertical speed into a horizontal budget** (Low, Confirmed). `TraversalMath.luau:40-48` returns `sqrt(up² + sep²)`; `effectiveMaxSpeed` (MVS:1087-1097) uses it as a *horizontal* cap. The horizontal budget is inflated by the residual vertical component for the first ~0.6 s. The window sampling limits the practical effect, but the semantics are wrong: cap horizontal by `WallBoostSeparationSpeed` and vertical separately (M-001).
- **M-025: Debug instrumentation left on in production paths** (Low, Confirmed). `SPEED_SANITY_DEBUG_LOGGING = true` (MVS:299) and `WALL_TRAVERSAL_DEBUG_LOGGING = true` (MVS:309) print per claim/rejection; the violation `print` at MVS:1312 is unconditional and unrate-limited per player (≤2/s each, cheaters can trigger it at will). Gate on `RunService:IsStudio()` or a config flag; route to the `ViolationTracker` sink (M-008).
- **M-026: Dangling doc references** (Low, Confirmed). 178 references to `docs/MOVEMENT.md` and 53 to `TRAVERSAL-ROADMAP.md` across `src`, `network.zap` and `docs/`; neither file exists (`docs/` holds `ARCHITECTURE.md`, `CLAUDE.md`, `Wall Run & Leap Mechanic Guideline.md`, `WallClimbingPlan.md`). The rationale behind 200+ decisions is unresolvable. Restore the docs or rewrite the references to point at `WallClimbingPlan.md §18` / the commit that recorded each decision.
- **M-027: Stale or contradicting comments** (Low, Confirmed). `HardLandingState.luau:22-25` says the server cap is 0 (it is 6, MVS:1037) and that the lock is authoritative (M-010); `MovementConstants.luau:359` says WallBoost rises "~9.8 studs at default gravity" (it is 120² / (2 × 196.2) ≈ **36.7**); MVS:341-344 calls client-owned CFrame/MoveDirection "server-trusted" (M-004); comments cite `AirborneState.ResolveLandingTarget` in places that now call `LandingResolution.Resolve` directly.
- **M-028: A tuning key must be edited in 8 places** (Low, Confirmed). Verified by script: 46 keys are consistent across `MovementConstants`, `TUNABLE_NAMES`, `Defaults()`, `VALID_RANGES`, the `TunableConstantName` union, `network.zap` enum + `TuningState` struct, `MovementTuningService` payload mapper, Client init mapper (`TuningSnapshot.Set`), and the overlay JSON `Row_*`. It is in parity today; the shape invites drift. Generate the payload/mapper from `MovementTuning.Names`, or send the table as an array of `{name, value}`.
- **M-029: Dev-tool hardening** (Low, Confirmed). Gate is sound (`RegisterDevOnly` is the only route, `DevToolsService.luau:44`; all six client→server remotes checked). Residual: `RequestDevTeleport` applies `Vector3.new(position.x, .y, .z)` without NaN/inf/range checks (lines 71-73; `write_checks` does not reject NaN); `IsDeveloper` is `IsStudio() or allowlist`, so any Team Test participant is a developer; the allowlist lives in `ReplicatedStorage` (readable by every client); noclip-off sets `CanCollide = true` on every character part, including accessory handles (lines 106-110), which is wrong for parts that were non-colliding; the whole overlay ScreenGui (`Enabled = true`, 46 tuning rows) is replicated to every player and is disabled only after `Init` runs.
- **M-030: Overlay per-frame cost** (Low, Confirmed). While open, the Heartbeat handler calls `UserInputService:GetFocusedTextBox()` twice and `TuningSnapshot.Get()` per key per frame (`DebugOverlayController.luau:641-650`); the `task.delay` at line 365 is not trove-tracked. Dev-only.
- **M-031: Magic numbers and style** (Low, Confirmed). ARCH §2/§7: `TraversalMath.luau:68` hardcodes the double-jump decay floor `0.5` in a function the server also calls (make it `DoubleJumpDecayFloorFraction`); `1e-3` epsilon appears 7 times across `TraversalMath`, `SpatialQueries`, `WallClingState`; `DebugOverlayController.luau:195,211,217` hardcode 10/5/8 that must equal `STATE_HISTORY_LIMIT`/`HISTORY_LIMIT`/`CLAIM_LOG_LIMIT` in other files; `LocomotionAnimator.luau:73-76` bucket math; 15 `:: any` casts (`InputController.luau:115,148` write `_forward` etc. through a string-built key, defeating `--!strict`); bare `for … in table` is used ~26 times versus `ipairs` once (§7 "ipairs for arrays"); multi-paragraph comment blocks conflict with §7's one-line-comment rule (but see §7 Q8: `docs/CLAUDE.md` endorses them).
- **M-032: Tuning change mid-state** (Low, Confirmed, dev-only). Server applies `SetOverride` immediately; the client applies `WalkSpeed` only on the next `Enter`, so lowering `SprintSpeed` mid-sprint rubber-bands until a state change. Push `_applySpeed()` on `TuningState`, or apply server overrides one frame after the client acknowledges.
- **M-033: `CollisionGroups.Apply` cost** (Low, Confirmed). It runs `character:GetDescendants()` and writes `CollisionGroup` on every part on every FSM transition on both sides (Client init:398, MVS:1234), even when the group name is unchanged (Idle↔Walk↔Run). Cache the last applied group per character and skip when equal; accessories added after `Apply` (HumanoidDescription) never join the group.
- **M-034: StreamingEnabled decision undocumented** (Low, Confirmed). ARCH §14 asks for a documented decision and, if enabled, the minimum radius; nothing states either. Risk is client-only under-prediction (safe direction).
- **M-035: No automated tests** (Low, Confirmed). The pure shared modules (`StateRules`, `TraversalMath`, `LandingResolution`, `StateMachine`) are ideal targets; a table-driven test over `Transitions` would have caught M-005.
- **M-036: `FacingController` lock direction is unguarded** (Nit, Plausible). `WallRunState` passes `entryTangent` to `SetLockDirection`; `FacingController.luau:58-62` does `CFrame.lookAt(pos, pos + lockDirection)`. `WallClingState` guards zero vectors with `1e-3`; WallRun does not. `TraversalMath.WallRunTangent` returns `Vector3.zero` for a vertical normal, which would produce a NaN CFrame.
- **M-037: WallLeap has no predicate or cooldown** (Low, Plausible). Topology-only gate (`StateRules.luau:150-157`); WallRun re-entry after a leap on the same wall is allowed (only WallCling checks `lastWallLeapWall`), so leap chains are limited only by the 5/s traversal limiter and geometry. Confirm intent (§7 Q3) before deciding whether this is a bug.

---

## 4. Architecture compliance checklist

**C** = compliant, **V** = violation, **P** = partial, **N/A** = not applicable to the movement scope.

| Rule | Status | Evidence / finding |
|---|---|---|
| §1 R6 only; no R15 branching | C | No `R15`/`UpperTorso`/`RigType` references |
| §1 Combat identity (parry, server hit validation) | N/A | No combat code yet |
| §2 Single entry point via Loader | C | `ClientBootstrap.client.luau:4-7`, `ServiceBootstrap.server.luau:4-7`; every controller/service exposes `Init` |
| §2 No stray Local/Script | C | Only the two bootstrap scripts |
| §2 FSM everywhere, `Symbol` states, LemonSignal | C | `StateMachine`, `MovementStates` (Symbols); `DEBUG_STATE_NAMES` is a boundary mapping only |
| §2 Strict pub/sub decoupling | P | `MovementTuningService` requires `DevToolsService` for `RegisterDevOnly` (helper on a service module); server uses `CharacterTeleported` event correctly |
| §2 Zero magic numbers | P | M-031 (0.5 decay floor, 1e-3 ×7, overlay row counts); per-file local constants (`TRANSITION_CLAIMS_PER_SECOND` etc.) are named but not in `MovementConstants` |
| §3 Client predicts, server decides | V | M-001, M-002, M-003, M-004 |
| §3 Server-side FSM mirroring | P | Mirror exists for all 15 states; driven by client-owned inputs (M-004); WallRun landing gap (M-005) |
| §3 Server-owned cooldowns | V | M-038; HardLanding lock client-only (M-010) |
| §3 Sanity raycasts on spatial claims | P | WallRun/WallCling/Slide re-cast server-side (good); "grounded" is not raycast-verified (M-004) |
| §4 Parry contract / lag compensation | N/A | Known issue (no pose-history utility) |
| §5 Anti-exploit: RateLimiter on every remote | C | All 6 client→server remotes limited (`RequestMovementTransition` 5/s, `ClaimTraversalMove` 5/s, three dev remotes, `RequestSetTuning` 5/s). Shared window drops CrouchUp (M-006) |
| §5 Exploit flagging | V | M-008 |
| §6 `os.clock`, no `tick` | C | Zero `tick()`/`wait()`/`spawn`/`delay` (grep) |
| §6 Throttled casts (dt accumulators) | C | Client accumulators; server `os.clock` throttles; M-021 for cast object reuse |
| §6 Every stateful object owns a Trove; destroy once; new Trove per life | P | Client `lifeTrove` is correct (verified); server sessions have none (M-023); module-scope state (M-022) |
| §7 `--!strict` | C | Every file |
| §7 Naming (PascalCase methods, camelCase locals, `_private`) | C | Grep found no camelCase methods |
| §7 Tabs / 100 col / no semicolons | C | `stylua --check src` clean |
| §7 `ipairs` for arrays | P | M-031 |
| §7 Never yield main thread; pcall fallible calls | C | `Init`s run through `SpawnAll`; overlay pcalls tweens |
| §7 Comments: one line, non-obvious only | V | M-031/§7 Q8: pervasive multi-paragraph comments |
| §8 GUI hand-built; scripts only `WaitForChild` | C | No GUI `Instance.new` (only `Attachment`/`LinearVelocity` in `CharacterMover.luau:73-77`); overlay tree is `MovementDebugOverlay.model.json`, `ResetOnSpawn = false` |
| §8 Session-locked persistence | N/A | No data in scope |
| §9 No band-aid validation | V | M-007, M-015 (unfixed root cause), M-017 |
| §10 Remotes only through Zap; fire-and-forget | C | 9 events (6 C→S, 3 S→C), no `RemoteFunction`, no raw `RemoteEvent` |
| §10 RateLimiter on player-initiated movement remotes | C | See §5 |
| §11 Network ownership for server-truth parts | N/A | Only the client-owned character exists; no server-truth parts |
| §12 HP not `Humanoid.Health`; `Died` not defeat | P | No misuse, but no defeat handling either (M-011) |
| §13 ProfileStore only | N/A | No `DataStoreService` in `src` |
| §14 StreamingEnabled documented | V | M-034 |
| CLAUDE checklist (7 non-negotiables) | P | Same as above |
| CONTRIB `selene src` / `stylua --check src` | P | stylua clean; selene not run |

---

## 5. Verified-OK list (checked and sound)

- **Tuning parity:** 46 keys identical across `MovementConstants`, `Defaults`, `VALID_RANGES`, the name list, `TunableConstantName` (zap), `TuningState` struct, service payload, client mapper, and 46 overlay `Row_*` instances (scripted).
- **Remote surface:** exactly nine events; all declared in `network.zap`; `write_checks = true`; claim payloads are enums with no client-supplied numbers, normals or tangents; every C→S handler acquires a `RateLimiter` first (dev handlers check authorization first, so unauthorized spam is dropped cheaply).
- **Dev gating:** `RegisterDevOnly` is the only registration path for teleport/noclip/tuning/overlay; `IsValidValue` rejects NaN, ±inf and out-of-range.
- **Claim legality reads server state:** WallRun/WallCling/Slide use server-side casts via `SpatialQueries`; the WallBoost envelope is computed from constants and `Workspace.Gravity` with no padding (`effectiveMaxSpeed`, MVS:1087-1097).
- **Sprint dwell:** owned by the server (`runEnteredAt`), backdate capped at half of `SprintThresholdSeconds`, demotion resets it (MVS:828).
- **StateMachine:** self-transitions rejected, `current` set before `changed`, signal owned by a Trove, `Destroy` present (`StateMachine.luau`).
- **`LinearVelocity` lifecycle:** created once per life, inert (`MaxAxesForce = 0`) between moves, destroyed by the trove; WallCling `Exit` clears the override before the drop nudge and before WallBoost's one-shot write.
- **`SetJumpBlocked`:** Exit-before-Enter ordering keeps the single boolean coherent across CrouchIdle/CrouchWalk/HardLanding/WallCling/WallBoost hand-offs; `Destroy` releases it.
- **Speed/jump writers:** `WalkSpeed`/`JumpPower` written only by `CharacterMover` on the client; server never writes them.
- **`peakHeight` ordering:** grow-only before `Update`, reset only inside `changed`; no same-frame landing race, on both sides.
- **Bounded memory:** `ViolationTracker` history 5, `DebugSnapshot` 10/8, `RateLimiter` ≤5 timestamps; per-player state cleared on `PlayerRemoving`.
- **Overlay:** dev-gated on both sides, no runtime UI construction, throttled (Heartbeat updates only when open), bounded row pools.
- **Animation assets:** all 27 slots authored, including WallBoost.
- **Frame-rate dependence:** Slide decay is `dt`-integrated, DoubleJump/WallRun timers use `os.clock`, query throttles use dt accumulators (client) or `os.clock` (server); no frame-count assumptions found.
- **Server Heartbeat ordering:** peak → wall probes → mirror → buffered retries → slide query → speed sanity → DoubleJump trajectory → broadcast is internally consistent with the same-frame-race comments.

---

## 6. Suggested fix order

**Batch 1: security core (do together; each depends on the previous)**
1. M-002 (audit every window; no baseline discard) → 2. M-004 (server ground truth via `QueryGround`) → 3. M-001 (vertical envelope) → 4. M-003 (allowance from server-known constants, time-bounded) → 5. M-038 (server-owned lockouts) → 6. M-008 (act on violations; zero velocity on correction).

**Batch 2: stuck states and parity bugs (independent, small)**
M-005 (edge + regression test), M-006 (crouch as resynced level), M-009 (buffer retry in DoubleJump / claim resync), M-012 (`InputController:Reset` + focus events), M-011 (dead gate), M-019 (apply group from `fsm.current`).

**Batch 3: measure, then remove padding (needs a playtest capture)**
M-007, M-017, M-016, M-015, M-014 (floor velocity + explicit exemptions), M-010, M-020 (live replication check first), M-024.

**Batch 4: lifecycle and performance**
M-021, M-022, M-023, M-033, M-030.

**Batch 5: hygiene and process**
M-025, M-026, M-027, M-028, M-029, M-031, M-032, M-034, M-035, M-036, M-037; run `selene src` and fix what it finds.

---

## 7. Open questions for the designer

1. **Devices:** are gamepad and mobile in scope for movement? Today only keyboard works (M-013).
2. **HardLanding:** should the lock be a server-enforced penalty (real cost to jump-cancel), or a client courtesy? That decides M-010.
3. **WallLeap chains:** may a player wall-run → leap → re-enter WallRun on the same wall repeatedly? If not, add a cooldown/same-wall rule (M-037).
4. **Vertical policy:** what vertical travel is legitimate (knockback, launch pads, vehicles, elevators, future Qinggong)? M-001's envelope has to whitelist those explicitly.
5. **Collisions:** should players collide with each other, and what should `CharacterCrouched` pass through (M-018)?
6. **Replication facts:** can someone run the two-line live-server check for `AutoRotate` and `MoveDirection` replication (M-020)?
7. **StreamingEnabled:** on or off, and at what radius (ARCH §14)?
8. **Comment policy:** ARCH §7 says one-line comments; `docs/CLAUDE.md` calls the thorough comments intentional. Which wins?
9. **Humanoid states:** what should happen while Swimming, Climbing, Seated, Ragdoll? Which count as "grounded" for DoubleJump reset (M-014)?
10. **Dev tools in production:** should the overlay and its UI exist in live servers at all, or be stripped at build time (M-029)?
11. **Acceptable false-flag rate:** what rubber-band frequency is tolerable, since it determines whether to tighten measurement (M-007, M-015)?
12. **Missing docs:** do `docs/MOVEMENT.md` and `TRAVERSAL-ROADMAP.md` still exist anywhere (M-026)?

---

## 8. Fix log

Status per finding as fixes land. "Fixed" means code changed and `stylua --check` + `selene` pass on the touched files; **none of these are playtested yet** unless stated.

`selene src` now runs locally: **0 errors, 0 warnings** (resolves the §2.4 "selene: unknown" item).

### 2026-09-24: Batch 2 (stuck states and parity)

| ID | Status | Change |
|---|---|---|
| M-005 | Fixed | `HardLanding` added to `StateRules.Transitions[WallRun]`. `LandingResolution` now asserts at require time that every landing caller (Airborne, DoubleJump, WallRun, WallCling, WallBoost) has an edge to every state `Resolve` can return, so this class of stuck state fails loudly on load instead of in play. |
| M-006 | Fixed | Client sends crouch as a level (`CrouchDown`/`CrouchUp`) on every edge **and** on the 1 s resync, in both directions (`fireCrouchLevel`, Client init). Server gates crouch claims with their own `crouchRateLimiter` (`CROUCH_CLAIMS_PER_SECOND = 5`) before the Run/Sprint limiter, so neither can starve the other; a dropped claim self-heals within 1 s. |
| M-009 | Fixed | `retryBufferedTraversalClaims` keeps WallRun/WallCling buffers alive while the mirror is still in `DoubleJump` (retries only once it reaches `Airborne`). Function restructured to one "abandon" condition per buffer, which also cleared three pre-existing `selene` `if_same_then_else` warnings. |
| M-011 | Fixed (movement-only) | Client: `Humanoid.Died` ends the movement life through a single `endLife` path shared with `CharacterRemoving`/replacement. Server: `Died` and `CharacterRemoving` destroy the session. Neither is a combat-defeat trigger (ARCH §12); the future `Defeated` state still has to own that. |
| M-012 | Fixed | `InputController:ReleaseHeldKeys()` on `WindowFocusReleased` and `TextBoxFocused` (WASD, `_jumpHeld`, double-tap timer); `InputController:Reset()` at the start of every life also clears the crouch toggle. Removed the string-built `(self :: any)["_" .. axis]` writes (part of M-031). |
| M-019 | Fixed | Client `fsm.changed` applies the collision group from `fsm.current`, not the stale `next`, after a reentrant SlideJump/WallLeap hand-off. |
| M-022 (partial) | Fixed: setup race only | `setupCharacter` bails out after its `WaitForChild` yields if the life was already replaced/removed, so nothing is added to a destroyed trove. Module-scope state reset is still open (Batch 4). |
| M-023 | Fixed | `PlayerSession` owns a `Trove` (FSM + `fsm.changed` + `Died`); single `destroySession` path for death, removal, replacement and leave; per-player `CharacterAdded`/`CharacterRemoving` connections in a per-player trove; stale-rig guard after `WaitForChild`. |
| M-013 | Unblocked | Q1 answered: keyboard only (see below). |

### 2026-09-24: Batch 1 (security core)

All server-side, `MovementValidationService` unless noted. `rojo build` passes. **Needs a playtest pass before it's trusted** — see "What to test" below.

| ID | Status | Change |
|---|---|---|
| M-002 | Fixed | Transitions and claim accepts no longer reset the speed window. The window's budget is accumulated every Heartbeat at whichever cap was live (`speedBudget`), so a window spanning several states is judged against the right mix of caps and nothing is ever discarded. The post-claim suspension (`speedSanitySuspendedUntil` / `TraversalSpeedSanityGraceSeconds`) is **removed**: 5 DoubleJump claims/s × 0.5 s suspension switched the check off entirely. The one real gap the old resets covered (a claim arriving one network leg after the client started the move) is now a `creditClaimLatency` budget credit: cap increase × (half the server-measured ping + time spent in a claim buffer), capped at one window. |
| M-004 | Fixed | New `SpatialQueries.QuerySupport` (R6 leg footprint Blockcast, collidable non-water geometry only). Server `grounded` = Humanoid label **and** real support; a supported character labelled airborne for a full speed window also counts as grounded (closes "report Freefall forever" to keep airborne caps/allowances). Used by the mirror, wall probes and the vertical ceiling. New constants: `RigRootHeightAboveFeet`, `GroundSupportFootprint`. |
| M-001 | Fixed | New vertical ceiling (`enforceVerticalCeiling`): re-anchored to Y + `BallisticRise(JumpPower)` whenever grounded, raised by each accepted move's max rise (`DoubleJumpMaxRise`, WallLeap/WallBoost `BallisticRise`, WallRun entry-snap bound). Excess must outlast `WallRunClaimBufferSeconds` (claim/replication ordering) before it's snapped down with upward velocity killed. Zero tolerance otherwise; `VERTICAL_CEILING_DEBUG_LOGGING` for measurement. Exemption hook: `Server/Events/VerticalAllowanceGranted` (Q4). `enforceDoubleJumpTrajectory` and its unmeasured `TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE = 15` are **removed** (superseded; part of M-017). |
| M-003 | Fixed | `wallLeapAllowedSpeed` = `TraversalMath.WallLeapMaxHorizontalSpeed(WallRunSpeed, WallRunClingMaxCorrectionSpeed, burst, push)`, an exact bound from constants (≈166 at current tuning vs. the old unbounded client velocity + 150). Cleared on landing (now server-verified) and on entering WallRun/WallCling (both overwrite velocity). Landing grace now uses the full effective cap from before the transition (`previousCap`), so a leap landing isn't flagged. |
| M-010 | Fixed | HardLanding is server-enforced (Q2): during the lock only the server's support probe can end it; losing support after rising more than the probe's reach above the lock position is a jump-out → violation + snap back to `hardLandingLockPosition`. A vanishing floor still drops to Airborne. Client/server comments corrected (part of M-027). |
| M-038 | Partly fixed | Post-boost cooldown now server-owned (applied on the mirror's WallBoost exit). **Drop lockout left client-only on purpose:** the server can't tell a Drop from a WallLost (both are inferred from the wall probe), and a drop gives no height, so the lockout has no security value. |
| M-024 | Fixed | WallBoost envelope removed from the horizontal cap (its horizontal part is `WallBoostSeparationSpeed`, already under every airborne cap); vertical is the ceiling's job. `TraversalMath.WallBoostSpeedCeilingAt` deleted (no callers). |
| M-008 | Partly fixed | Every correction now also kills the relevant velocity. Vertical/HardLanding corrections recorded in a separate `verticalViolations` tracker. **Escalation policy (flag/kick) still open — needs a design decision.** |

**Known residuals:**
- The vertical ceiling stacks each accepted rise on the previous ceiling, so it's a safe upper bound but loose. Example: a DoubleJump pressed on the way down still allows the full remaining jump height on top. A cheater gains at most one Humanoid jump's height (~7.7 studs) over legit play per airborne stretch, and never unbounded flight.
- The ceiling doesn't detect hovering or slow-falling at or below it (HardLanding evasion by floating down). That needs a gravity/descent check, and the check needs measured replication jitter first (Batch 3).
- Humanoid `Climbing` (trusses/ladders), `Seated` in a moving vehicle, and `Swimming` get no special handling. Truss climbing will trip the ceiling (§7 Q9 still open).

**What to test (Studio, ideally with incoming replication lag on):** normal jump, DoubleJump at the apex, WallRun → WallLeap → land, WallCling → WallBoost chains up a tall wall, sprint-jumping around for a minute (no `[SpeedSanity]` prints), HardLanding with Space spam, standing on a ledge edge, standing on another player's head. Turn on `VERTICAL_CEILING_DEBUG_LOGGING` and `SPEED_SANITY_DEBUG_LOGGING` and note any honest-play excess.

### 2026-09-24: Batch 4 (lifecycle and performance)

| ID | Status | Change |
|---|---|---|
| M-021 | Fixed | `MovementTuningState.GetEffective` returns a cached, frozen table (a shared frozen defaults table for players with no overrides; rebuilt only on Set/ClearOverride) instead of allocating 46 fields per call. `SpatialQueries` reuses two module-level `RaycastParams` instead of one per cast. `buildContext` reads `GetState()` once. |
| M-022 | Fixed | Every stateful client state module (Airborne, Run, Slide, DoubleJump, HardLanding, WallRun, WallCling, WallBoost) has a `Reset()`, all called at the start of each life. |
| M-023 | Fixed (remainder) | `DevToolsService` and `MovementTuningService` keep their per-player `CharacterAdded` connections in per-player troves destroyed on leave. |
| M-033 | Fixed | `CollisionGroups.Apply` skips the descendant walk when the group hasn't changed (weak-keyed cache). New `CollisionGroups.Watch` puts parts added later (accessories, tools) into the current group, owned by the life's/session's trove. |
| M-030 | Fixed | Overlay reads the focused TextBox and tuning snapshot once per frame, not once per row; the fade-out hide is one cancellable thread owned by the trove. |

### 2026-09-24: Batch 5 (hygiene)

| ID | Status | Change |
|---|---|---|
| M-018 | Fixed | New `CrouchPassable` collision group that crouched/sliding characters don't collide with (standing ones do). Level authors put low bars/vents in it. Player-vs-player collision stays on (Q5). |
| M-025 | Fixed | `SPEED_SANITY_DEBUG_LOGGING` and `WALL_TRAVERSAL_DEBUG_LOGGING` now default off; the per-violation print only runs in Studio (or with the flag). |
| M-026 | Fixed | `docs/MOVEMENT.md` restored from git (`dcebeab^`, where it was deleted) and `docs/TRAVERSAL-ROADMAP.md` added from the copy in Downloads (never committed). Both carry a "historical record, not kept current" banner. All ~230 references now resolve; no comments rewritten. |
| M-027 | Fixed | WallBoost rise comment corrected (≈36.7 studs, not 9.8); HardLanding and `classifyMoveIntent` comments corrected in Batch 1. |
| M-028 | Fixed | `TuningState` is now a list of `{name, value}` pairs on the existing `TunableConstantName` enum (`MovementTuning.ToEntries/FromEntries`); `Defaults()` is built from the name list; a require-time assert checks every name has a numeric constant and a range. A new tunable touches 5 places instead of 8, and the two 46-line mappers are gone. |
| M-029 | Fixed | Dev teleport rejects NaN/inf coordinates; noclip-off restores each part's own `CanCollide` instead of forcing `true`. (Allowlist location and the replicated overlay GUI left as-is — §7 Q10.) |
| M-031 | Fixed | `DoubleJumpDecayFloorFraction` and `DirectionEpsilon` constants replace the literals; overlay row pools sized from exported `StateHistoryLimit`/`ClaimLogLimit`/`HistoryLimit`; animator bucket math derived from `DIRECTION_NAMES`; all 31 generalized `for ... in t` loops converted to `ipairs`/`pairs`; InputController's string-built `:: any` writes removed. Other `:: any` casts are the metatable-constructor idiom and were left. |
| M-032 | Fixed | A live tuning change re-applies the current grounded tier's WalkSpeed immediately (`TIER_SPEED` in Client init). |
| M-036 | Fixed | `FacingController:SetLockDirection` flattens the direction and treats a near-zero one as "no lock", so a NaN CFrame is impossible. |
| M-013 | Documented | Keyboard-only (Q1) documented in `InputController`; confirmed non-keyboard players don't desync (their Idle WalkSpeed equals the server's Walk cap). |
| M-034 | Open | StreamingEnabled isn't set in `default.project.json`, so it lives in the place file — §7 Q7. |
| M-035 | Partial | No test runner in the toolchain. Require-time invariant checks now cover the two most drift-prone tables (landing edges, tuning keys). A real runner (e.g. Lune for the pure shared modules) is still open. |
| M-037 | Open | Needs §7 Q3 (are same-wall WallLeap chains intended?). |

### 2026-09-24: Batch 3 (tolerances and parity)

| ID | Status | Change |
|---|---|---|
| M-017 | Fixed | `SpeedToleranceMultiplier` removed from live tuning (MovementTuning, zap enum, overlay row); the server reads the constant. `TRAVERSAL_VERTICAL_VELOCITY_TOLERANCE` was already removed in Batch 1. |
| M-007 | **Needs a capture** | The 1.3 multiplier is still unmeasured. New `SPEED_RATIO_CAPTURE` flag in `MovementValidationService` prints the p50/p99/p99.9/max of real displacement ÷ allowed budget every 200 windows. Set the multiplier to honest play's p99.9 and cite it next to the constant. |
| M-016 | **Needs a capture** | WallCling's zero cap: the same capture reports `zeroBudgetDriftMax` (studs moved in zero-budget windows). If honest clinging drifts, that number is the measured cause to document. |
| M-015 | **Needs a capture** | Burst-after-stall false positives. The budget accumulator already covers stalls shorter than a window; longer ones show up in the ratio capture's tail. A stall credit needs that measurement first. |
| M-014 | Fixed (physics floors) | `QuerySupport` returns the floor's velocity at the contact point; its horizontal speed is added to the budget. Covers physics platforms, vehicle seats, and standing on other players. Anchored parts moved by CFrame/tween report zero velocity and are **not** covered. Climbing/Swimming/Seated handling is still §7 Q9. |
| M-020 | Fixed | New `CameraLocked`/`CameraUnlocked` level claims (shared `levelRateLimiter`, now 6/s) replace the server's `Humanoid.AutoRotate` reads, which never replicated. The server's Sprint→Run backpedal demotion now actually runs. |
| M-010, M-024 | Fixed in Batch 1 | — |

### 2026-09-24: Designer follow-ups

| ID | Status | Change |
|---|---|---|
| M-008 | Fixed | New `Server/Events/MovementViolation` signal `(player, kind, detail, count)`, fired for every correction (`Speed`, `VerticalCeiling`, `HardLandingEscape`) through one `reportViolation` helper. No kick/flag policy in the validation service; a future moderation system subscribes. Also fixed: the Batch 1 vertical tracker was never cleared on leave. |
| M-037 | Fixed | No WallLeap chains (Q3): `CanEnter[WallRun]` rejects the wall just leapt from until landing, reusing the `lastWallLeapWall` memory WallCling uses. Shared, so client and server agree. Covered by a unit test. |
| §7 Q9 | Fixed (ladders, swimming) | New `SpatialQueries.QueryClimbable` (something collidable in front of the torso) and `IsInWater` (terrain water voxels at the root). Vertical ceiling: swimming in real water re-anchors like ground; climbing on something real lets the ceiling rise at no more than the player's speed cap, never more than one jump above their actual position. Fall height resets while swimming on both client and server, so a dive into water followed by climbing out no longer forces HardLanding. Seats in moving vehicles are covered by M-014's floor velocity. |
| M-034 | Documented | StreamingEnabled recorded as **on** in ARCHITECTURE §14, with its movement consequences. **TODO:** confirm in Studio and record the radii. |
| M-035 | Fixed | Lune 0.10.5 added to `aftman.toml`. `tests/harness.luau` maps the Rojo tree to files so shared modules load unmodified; `tests/run.luau` runs `tests/specs/*.spec.luau`. **38 tests** cover StateRules, LandingResolution, StateMachine, MovementTuning and TraversalMath, including simulations proving `DoubleJumpMaxRise` bounds the client's rise at 20–240 fps and `WallLeapMaxHorizontalSpeed` bounds every possible leap. Wired into CI; documented in README/CONTRIBUTING. A deliberate mutation (removing the M-037 check) was caught. |

**Still open:** the three Batch 3 captures (M-007/M-015/M-016, need a Studio playtest), StreamingEnabled radii, and CFrame-tweened moving platforms (not covered by M-014).

### Designer answers (2026-09-24)

| §7 question | Answer | Consequence |
|---|---|---|
| Q1 Devices | **Keyboard only for now** | M-013: document keyboard-only; non-keyboard players must still not desync from the server. |
| Q2 HardLanding | **Server-enforced** | M-010: leaving HardLanding early is legal only when the server's own ground check says the floor is gone; otherwise it's a violation. |
| Q4 Vertical policy | **Current moves + a generic exemption hook** | M-001: allowed rise comes from the real impulses (jump, DoubleJump, WallLeap, WallBoost), plus one server API that future knockback/launchers/Qinggong call to grant a vertical allowance. |
| Q5 Collisions | **Keep player-vs-player collision** | M-014/M-018: the speed check must subtract the velocity of the surface the player stands on. |
