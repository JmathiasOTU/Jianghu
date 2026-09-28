# Flow — Design Slice

Status: **built 2026-09-28, not yet playtested.** The prerequisite (slide-jump landing resume, §0)
is done and confirmed in a playtest. How Flow works now lives in
[`MovementSystem.md`](MovementSystem.md) §4.9 and §8.2. This file keeps the design reasoning and the
open questions (§7) until a playtest settles them, then it's retired, the same way the older
movement docs were.

Reference footage (Kaizen 2, ~18 s clip): the longer a player chains wall runs, slides, vaults and
leaps back to back, the higher their real top speed gets (speed lines intensify), and it fades back
over a couple of seconds once they stop chaining. That's a **persistent, decaying resource that
raises the real speed ceiling**. Nothing like it exists in the codebase today.

---

## 0. Decisions

| Question | Decision |
|---|---|
| Prerequisite | **Slide-jump landing resume, done first.** A slide jump used to always land in Walk, because `preAirborneLocomotion` was only set on a Run/Sprint → Airborne edge and a slide jump leaves from SlideJump. Flow would fight that (a big bonus, then a reset one move later). Fixed 2026-09-28: both sides record the tier a slide was entered from (`slideEntryLocomotion`), and leaving the ground from Slide/SlideJump carries it into `preAirborneLocomotion` (`MovementSystem.md` §4.4). Confirmed in a playtest the same day. |
| What builds it | **Qualifying moves, in any order** (confirmed with the project owner): entering `SlideJump`, `WallRun`, `WallLeap`, `WallBoost`, `Vault`, `DoubleJump`. Not `WallCling` (a hold; the boost from it counts) and not Run/Sprint/Walk. Holding Sprint in a straight line never builds it. |
| Sprint only | **Flow only exists inside a sprint chain** (designer, 2026-09-28, after a playtest built Flow from Walk/Run takeoffs and ran into speed corrections). The chain starts on entering Sprint, survives every airborne and slide state after it, and ends on touching down in any other grounded state (Walk, Idle, Run, Crouch, HardLanding). A vault carries it when it lands back in Sprint (vaults keep your sprint since 2026-09-28). Moves only gain inside the chain, and Flow drops to zero the moment it ends. Landing back into Sprint keeps it, draining normally. `Shared/Movement/FlowRules.luau`, used identically by both sides. |
| What it does | **Raises the real, server-enforced speed cap** (confirmed with the project owner), so it's exploit-relevant: the server derives its own copy and never trusts the client's (`ARCHITECTURE.md` §3). |
| Name | **Flow** (decided 2026-09-28), in code, constants, debug output and UI copy. Not "momentum": this codebase already uses that word for residual velocity (the landing-momentum grace, `VaultHorizontalMomentumKeep`, many comments). |
| Representation | One `number` in `[0, 1]`, gained in flat steps, drained linearly after a grace period. Closed-form, like `SlideDecayRate`. |
| Which speeds it scales | **Horizontal base speeds of the fast states only:** Sprint, WallRun, and the slide ceiling (Run never has Flow under the sprint-only rule). Launches (SlideJump, WallLeap, Vault) are **not** multiplied directly: they already build on the speed you had, so Flow reaches them through those inputs. **Never vertical:** JumpPower, `SlideJumpUpwardSpeed`, `WallLeapUpwardForce`, `WallBoostUpwardForce`, DoubleJump and the vault launch stay as they are, so the vertical ceiling (§8.3) needs no change. Idle, Walk, Crouch, HardLanding and WallCling are never scaled on either side. |
| Server trust | **Never trusts a client value.** The server keeps its own `session.flow`, gained on its own mirror's transitions and decayed on its own clock. No new remote, no new claim payload. |
| Decay shape | Grace (`FlowDecayDelaySeconds`) after the last gain, then linear drain (`FlowDecayRate`). |
| vs `context.qinggong` | **Separate field.** Qinggong is an open combat-resource question (`MovementSystem.md` §14); Flow doesn't wait on it. |
| New network events | **None for gameplay.** One optional dev-only field on `MovementDebugState` (§6). |
| New tunables | Four feel constants, F4-tunable: `FlowGainPerMove`, `FlowMaxSpeedBonus`, `FlowDecayDelaySeconds`, `FlowDecayRate`. None is a validation tolerance: the server's bound follows the same tuned values, so tuning changes the bonus, never what counts as legal for a known Flow value. |

---

## 1. Shared math (`TraversalMath.luau`)

Three pure functions, called identically by both sides and spec-tested (§8):

- `FlowAfterGain(flow, gainPerMove)` → `math.min(1, flow + gainPerMove)`
- `FlowAfterDecay(flow, sinceLastGain, dt, delaySeconds, rate)` → unchanged inside the
  grace period, then `math.max(0, flow - rate * dt)`
- `FlowMultiplier(flow, maxBonus)` → `1 + flow * maxBonus`

The qualifying states go in one shared set, `MovementStateGroups.FlowBuilding`, so the two
sides can't drift apart on what counts.

---

## 2. State

**Client** (`Movement/init.luau`, per-life locals next to `preAirborneLocomotion`): `flow = 0`,
`lastFlowGainAt: number? = nil`.

**Server** (`Sessions.luau`, initialized in `createSession`): the same two fields, plus
`heldFlowMultiplier: number?` (§4).

**Context** (`MovementTypes.luau`, both builds): `flowMultiplier: number`, already computed.
States consume a multiplier, never the raw curve.

Both reset each life (new locals / new session). A teleport doesn't reset it.

---

## 3. Gain and decay

**Gain:** in each side's `fsm.changed` handler. Client: `Movement/init.luau`. Server:
`TransitionBookkeeping`, **after** the `previousCap` snapshot, so the landing grace doesn't record a
cap the previous state never had. When `next` is in `FlowBuilding`: apply
`FlowAfterGain`, stamp `lastFlowGainAt = os.clock()`. That's one place per side instead of
one line per claim branch. Claimed moves reach it through `fsm:RequestTransition` at accept, which
runs before `ClaimTiming.CreditClaimLatency` computes `capAfter`, so the claim latency credit covers
the Flow raise too (the client gained one network leg earlier).

**Decay:** once per frame with that frame's `dt`. Client: the orchestrator's existing Heartbeat
connection. Server: **its own step in the Heartbeat order** in `MovementValidationService/init.luau`,
before the speed check. **Not** at the top of `Mirror.PassiveTransitions`, which
`TraversalClaims` also calls between Heartbeats (to refresh the mirror before judging a claim), so
decay there would drain extra on every claim.

**Why the server stays at or above the client:** the server gains at its accept, up to one claim
lag after the client, so its grace period starts later. That alone isn't enough: the lag varies
per claim, so if one claim arrives fast and the next slow, the server drains longer between them
than the client did and briefly sits below it. So the server's drain also starts one
`ClaimTiming.ClaimLagSeconds` later than the client's (`Flow.Decay`), the same way the vertical
ceiling's descent starts one claim lag late. `Flow.spec` simulates jittered arrivals and checks the
server never trails while no gain is in flight; without the extra delay it fails. All of this holds
only if the server accepts every move the client counted (see residuals, §7).

---

## 4. Server caps (`SpeedCaps.luau`)

**Apply the multiplier inside `maxSpeedForState`, per state, not at the end of `CapForState`.**
Multiplying the final cap would:
- scale Idle/Walk/Crouch/HardLanding, which the client never boosts (loosening for nothing), and
- multiply `airborneAllowedSpeed` again, even though the allowances are built from already-boosted
  inputs (below).

Per state:

| State | Cap |
|---|---|
| Sprint, WallRun | base × live multiplier |
| Slide, SlideJump, Airborne, DoubleJump, WallLeap, WallBoost, Vault | base × max(live, `heldFlowMultiplier`) |
| Idle, Walk, CrouchIdle, CrouchWalk, HardLanding, WallCling | unchanged |

**Why a held multiplier:** in the air or mid-slide, the client's speed is fixed at launch or entry and
doesn't follow Flow down. Nothing slows horizontal flight, and a slide decays at its own rate.
A live-decaying cap would drop under a legitimately fast flight and snap the player back.
`heldFlowMultiplier` = max(itself, live) on every edge into Slide or an airborne-family state,
cleared on the landing edge (`GROUNDED_STATES[next]`), alongside `airborneAllowedSpeed`. Sprint and
WallRun can use the live value, because the client reapplies it every frame (§5).

**Launch allowances**, computed at accept like today, with boosted inputs:
- **WallLeap:** `WallLeapMaxHorizontalSpeed(constants.WallRunSpeed * multiplier, ...)`. The leap
  launches at WallRun's speed + burst, and WallRun's speed carries the multiplier. The burst and
  push are not scaled.
- **SlideJump / Slide:** the ceiling becomes `SprintSpeed × multiplier × SlideEntrySpeedMultiplier`.
  Move `SpeedCaps.SlideCeiling` into `TraversalMath` so `SlideState`/`SlideJumpState` (which
  compute it inline today) and the server share one function. `TransitionBookkeeping`'s
  `slideEntrySpeed` uses the same boosted `SprintSpeed`, so the mirror's decay estimate still
  matches the client's (a boosted slide lasts longer).
- **Vault:** nothing new. `VaultMaxHorizontalSpeed` already takes `capBefore`, which now carries the
  multiplier.

None of these are multiplied again inside `CapForState`.

---

## 5. Client consumption

- **Sprint reapplies every frame.** `SetSpeed` is only called on a state's `Enter`, so a bonus
  applied there would stay while Flow drains, and the server's live cap would correct the
  player. `CharacterMover` already reapplies `WalkSpeed` every Heartbeat for the landing slow
  (`_applySpeed`). Add a Flow factor there: `SetFlowMultiplier(m)`, called by the
  orchestrator after decay each frame, applied only when the current speed was set as boosted
  (`SetSpeed(speed, true)` from Sprint `Enter`; every other tier keeps the plain call).
- **WallRun:** `WallRunSpeed × context.flowMultiplier`, read each tick where the tangent
  velocity is built.
- **Slide:** scale the **entry clamp** only (`math.min(velocity.Magnitude, SprintSpeed × multiplier)`).
  The entry already starts from the real, boosted velocity, so also multiplying the per-tick output
  would count the bonus twice.
- **SlideJump:** scale the ceiling only (the shared `SlideCeiling`), not the boost amount.
- **WallLeap, Vault:** no change. Both launch from the current velocity, which already carries it.

---

## 6. Constants, tuning and debug

| Constant | Purpose | Starting point (untuned) |
|---|---|---|
| `FlowGainPerMove` | Step per qualifying move, clamped at 1 | 0.2 (5 moves to full) |
| `FlowMaxSpeedBonus` | Extra speed at full Flow | 0.5 (+50%) |
| `FlowDecayDelaySeconds` | Grace after the last gain | 1.5 |
| `FlowDecayRate` | Drain per second after the grace | 0.33 (full to zero in ~3 s) |

At these values, full Flow puts Sprint at 60, WallRun at 52.5 and the slide ceiling at 75, and
WallLeap's horizontal bound goes from about 166 to about 173 (only the WallRun-speed term grows; the
fixed burst and push dominate).

Adding them follows the usual four places (`MovementSystem.md` §10): `MovementConstants`,
`MovementTuning` (name + range), the `TunableConstantName` enum in `network.zap`, and four `Row_*`
in the F4 overlay (built in Studio). Update the tunable count in `MovementSystem.md` §10.

**Debug:** add `flow: f32` to `MovementDebugState` (dev-only, overlay-open only) and show client
vs server Flow on the F4 Movement tab. That's how a playtest confirms §3's claim that the server
stays at or above the client.

---

## 7. Open questions and residuals

**Needs a playtest:**
- **Long WallRun:** only entry counts, so a run longer than the grace period starts draining
  mid-run. That rewards chaining distinct moves over holding one. Confirm it reads right, or re-arm
  the grace while wall-running.
- **Banking:** landing back into Sprint after a chain keeps the bonus through the grace period and
  the drain (about 4.5 s at the starting values). Is straight-line sprinting at +50% for that long
  OK? Stopping or backpedalling already ends it (Sprint demotes to Idle/Run, which ends the chain).

**Residuals to record in `MovementSystem.md` §14 once shipped:**
- A move the client counts but the server rejects (or never receives) leaves the client ahead.
  Its Sprint/WallRun speed is then above the server cap until the chain ends or the extra drains, and speed
  corrections can fire. It should be rare: a rejected claim usually means the move didn't happen
  on the server either.
- The air-family cap uses the held multiplier for any takeoff, including a jump from Walk. A small
  loosening (a Walk jump can't reach it), accepted to keep one rule.

**Out of scope:** HUD/VFX. `MOVEMENT_POLISH_ARCHITECTURE.md` is the home for it (speed-line
intensity, an FOV kick). It can read `context.flowMultiplier`. Until then a developer-only test
meter shows Flow as a vertical bar on the left edge: `FlowBarController.luau` plus
`Assets/UI/FlowBar.model.json` (mapped in `default.project.json`). Delete all three to remove it.

---

## 8. Files (as built)

```
src/Shared/Movement/TraversalMath.luau                -- FlowAfterGain/AfterDecay/Multiplier, SlideCeiling
src/Shared/Movement/FlowRules.luau                    -- sprint chain: ChainAfter, Gains
src/Shared/FSM/MovementStateGroups.luau               -- FlowBuilding, FlowHolding sets
src/Shared/Types/MovementTypes.luau                   -- flowMultiplier on MovementContext
src/Shared/Constants/MovementConstants.luau           -- 4 Flow constants
src/Shared/Movement/MovementTuning.luau               -- 4 names + ranges

src/Client/Controllers/Movement/init.luau             -- flow state, gain in fsm.changed, decay +
                                                         SetFlowMultiplier each Heartbeat
src/Client/Controllers/Movement/Core/CharacterMover.luau    -- Flow factor in _applySpeed
src/Client/Controllers/Movement/States/SprintState.luau     -- SetSpeed(SprintSpeed, true)
src/Client/Controllers/Movement/States/WallRunState.luau    -- WallRunSpeed x multiplier
src/Client/Controllers/Movement/States/SlideState.luau      -- entry clamp x multiplier
src/Client/Controllers/Movement/States/SlideJumpState.luau  -- shared SlideCeiling, never below the slide
src/Client/State/DebugSnapshot.luau                   -- flow
src/Client/Controllers/DebugOverlayController.luau    -- client/server Flow rows

src/Server/Services/MovementValidationService/Flow.luau                 -- new: gain, held, drain
src/Server/Services/MovementValidationService/Sessions.luau             -- 3 fields
src/Server/Services/MovementValidationService/init.luau                 -- field init, drain step
src/Server/Services/MovementValidationService/TransitionBookkeeping.luau -- Flow.OnTransition,
                                                                            raised slideEntrySpeed
src/Server/Services/MovementValidationService/SpeedCaps.luau            -- per-state multiplier
src/Server/Services/MovementValidationService/TraversalClaims.luau      -- raised WallLeap bound
src/Server/Services/MovementValidationService/Mirror.luau               -- held-Flow SlideJump allowance
src/Server/Services/MovementValidationService/Context.luau              -- flowMultiplier
src/Server/Services/MovementValidationService/DebugBroadcast.luau       -- flow

network.zap                                           -- 4 TunableConstantName entries,
                                                         flow on MovementDebugState
Assets/UI/MovementDebugOverlay.model.json             -- 4 Row_Flow* + a RowFlow in each section
tests/specs/Flow.spec.luau                            -- math, server-vs-client simulation,
                                                         raised bounds
tests/specs/FlowRules.spec.luau                       -- the sprint chain
tests/fixtures.luau                                   -- flowMultiplier = 1
docs/MovementSystem.md                                -- §4.9, §8.2, §10, §12, §13, §14
```
