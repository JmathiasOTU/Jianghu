# Movement System

Living design + implementation doc for the movement FSM. Update this as states get
built, decisions change, or numbers get tuned — this is not a one-time spec.

**Active build scope (Phase 1): Idle, Walk, Run, Sprint, Airborne (jump + fall).**
None of these five are gated by stamina/Qinggong — that resource only matters for
WallRun/ClimbVault/LedgeGrab/Slide, which aren't built yet. See **Deferred** at the
bottom for a pointer, not a full spec.

Movement is **strafe-style**: facing is decoupled from movement direction (you face
wherever the camera/aim points; input direction relative to that facing selects
among your 8 directional animations). Target feel: fast and fluid, momentum-
preserving, generous air control.

## Implementation Status

| Piece | State | Files |
|---|---|---|
| Shared scaffolding (Step 1) | Done — 2026-09-13 | `Shared/FSM/MovementStates.luau`, `Shared/FSM/StateMachine.luau`, `Shared/Constants/MovementConstants.luau`, `Shared/Types/MovementTypes.luau`, `Shared/Movement/StateRules.luau`, `network.zap` |
| Core states (Step 2) | Not started | — |
| Facing + animation (Step 3) | Not started | — |
| Exploit + perf pass (Step 4) | Not started | — |

---

## 1. FSM Design Philosophy

One generic, reusable FSM engine (`Shared/FSM/StateMachine.luau`, LemonSignal-based)
drives movement. The FSM itself contains **zero movement logic** — its only job is:
is this transition legal, and if so, exit the old state and enter the new one. All
behavior lives inside the state modules themselves.

```
Input (UserInputService)
   -> Intent (MoveIntent, JumpIntent, RunIntent, ...)      [abstracted, not raw keys]
   -> FSM:requestTransition(state, context)                [Symbol-keyed, legality-checked]
   -> State module (Enter / Update / Exit)                  [owns its own behavior only]
   -> CharacterMover                                        [narrow physics interface]
   -> Humanoid
```

Note there's no `SprintIntent` — nothing the player presses maps directly to Sprint.
See §2.

Each state module exposes the same contract:

| Function | Responsibility |
|---|---|
| `CanEnter(context)` | Pure legality check — no side effects. Shared between client and server. |
| `Enter(context)` | One-time setup. |
| `Update(dt, context)` | Per-frame behavior while active. |
| `Exit(context)` | Teardown — always symmetric with `Enter`. |

`CanEnter` lives in `Shared/Movement/StateRules.luau`, so client and server evaluate
the exact same legality logic.

**On the Walk → Run → Sprint ladder:** Walk and Run are freely reachable whenever
their input conditions are met — don't gate `Run.CanEnter` on "currently in `Walk`."
Sprint is the one exception, and it's an *intentional* gate, not an FSM anti-pattern:
`Sprint.CanEnter` requires having been continuously in `Run` for the threshold
duration (§2). That's a real gameplay rule (you earn Sprint by sustaining Run), not
laziness standing in for a proper legality check.

States never talk to each other directly. A state that needs another system's data
subscribes to the relevant shared state module rather than reaching into that
system's controller — this pattern is what will let a later Qinggong/stamina system
gate WallRun without WallRun's state module knowing anything about how stamina is
tracked internally.

### FSM engine API (resolved 2026-09-13)

The repo already had a minimal `StateMachine.luau` (static adjacency table, no
context). Rather than add a second `FSM.luau` engine or bolt a `StateRules` check on
top as a second call sites must remember to sequence correctly, `StateMachine.luau`
was extended in place so legality + execution stay atomic in one call — this avoids
a real safety hazard where client and server code could each get the check/execute
ordering wrong independently.

```luau
StateMachine.new(initial, transitions, rules)
-- transitions: { [State]: {State} }               -- topology: which states CAN reach which
-- rules:       { [State]: (context) -> boolean }?  -- CanEnter: is it legal RIGHT NOW

fsm:requestTransition(next, context) -> boolean
-- Checks adjacency AND (if present) rules[next](context) before transitioning.
-- Returns false and does nothing if either check fails.

fsm:canTransition(next, context) -> boolean  -- same checks, no side effect
fsm:destroy()                                -- Trove:Destroy(), disconnects `changed`
```

`transitions` is pure topology (graph shape); `rules` is the dynamic per-target
`CanEnter` predicate, sourced from `Shared/Movement/StateRules.luau` so client and
server construct their FSM instances identically.

---

## 2. Input & Transition Triggers

- **Walk** — entered from `Idle` on any directional input while grounded. Covers all
  8 directions; which of the directional animations plays is `LocomotionAnimator`'s
  job (§4), not the FSM's.
- **Run** — entered from `Idle` or `Walk` on a **double-tap of W** registered within
  `MovementConstants.RunDoubleTapWindowSeconds` (**0.3s**, decided 2026-09-13). This
  is a discrete input pattern `InputController` detects and turns into a `RunIntent`
  — the tap window itself is a constant, not a hardcoded value inside the detector.
- **Sprint** — **not input-triggered at all.** `RunState.Update` tracks how long
  (`os.clock()`-based) the player has been continuously in `Run`; once that crosses
  `MovementConstants.SprintThresholdSeconds` (**3s**), `RunState` itself calls
  `FSM:requestTransition(Sprint, context)`. This is a state timing itself into the
  next one — same transition mechanism as everything else, just triggered internally
  by `Update` instead of by an `Intent`.
- **Losing forward input** (W released, or forced into `Airborne`) drops back down
  and the Run dwell timer resets on `Exit`. "Run for 3 seconds continuously" reads as
  *uninterrupted* — a jump or a stop restarts the clock rather than pausing it.
- **Sprint vs. strafing** (resolved 2026-09-13): Sprint tolerates forward-diagonal
  input (forward+strafe combined) but drops back to `Run` on a pure sideways or
  backward direction change — it does not persist through backpedal or pure strafe,
  and it does not require releasing W entirely to end.

`Sprint.CanEnter`'s real condition is therefore "mirrored as having been continuously
in `Run` for ≥ threshold" — never "sprint key held," because there is no sprint key.

- **Airborne landing** (resolved 2026-09-13): `AirborneState.Exit` checks currently
  held input directly and transitions straight into `Idle`/`Walk`/`Run` — never lands
  into `Sprint` (that has to be earned fresh via a new dwell period in `Run`), and
  never passes through an intermediate `Idle` frame first.

---

## 3. Module Layout

```
Shared/
  FSM/
    StateMachine.luau         -- generic LemonSignal-based FSM engine (extended, see above)
    MovementStates.luau       -- Symbol definitions: Idle, Walk, Run, Sprint, Airborne
  Constants/
    MovementConstants.luau    -- speeds, jump power, RunDoubleTapWindowSeconds,
                                  SprintThresholdSeconds — all numeric, nothing inline
  Types/
    MovementTypes.luau        -- strict type defs: MoveIntent, MovementContext, etc.
  Movement/
    StateRules.luau           -- CanEnter() legality predicates + the ladder's
                                  transitions topology, shared client/server

Client/Controllers/Movement/
  MovementController.luau      -- Init entry point, owns the FSM instance + Trove
  InputController.luau         -- raw input -> Intent; owns the W double-tap detector
  CharacterMover.luau           -- narrow physics interface states call into
  States/
    IdleState.luau
    WalkState.luau
    RunState.luau               -- owns the Run->Sprint dwell timer and self-transition
    SprintState.luau
    AirborneState.luau
  Presentation/                 -- purely cosmetic, never touched by states or FSM
    FacingController.luau       -- aligns character orientation to camera/aim each
                                    frame, fully decoupled from movement direction
    LocomotionAnimator.luau     -- picks/blends among the 8 directional Walk/Run
                                    anims from (facing-relative input angle, current
                                    state); reads the FSM, never writes to it

Server/Services/Movement/
  MovementValidationService.luau  -- server-side FSM mirror per player, rejects
                                      illegal transitions using the same StateRules;
                                      stores state-entry timestamps (not just the
                                      current Symbol) so it can independently verify
                                      earned transitions like Sprint
```

Note the layout deliberately follows the repo's existing generic `Constants/`/`Types/`
folders (each holding one file per domain) rather than inventing a parallel
`Movement/MovementConstants.luau` / `Movement/MovementTypes.luau` — `Shared/Movement/`
is reserved for movement-specific *logic* (`StateRules`) that doesn't fit those
generic folders.

Both `ClientBootstrap.luau` and `ServiceBootstrap.luau` pick these up automatically
via `Loader.LoadChildren` — no manual wiring needed beyond dropping the module in
the right folder.

---

## 4. Physics Model

All five Phase 1 states drive off `Humanoid:Move()` and `Humanoid.WalkSpeed`/
`JumpPower`, sourced from `MovementConstants` (one speed constant per ladder tier).
No custom `LinearVelocity`/`VectorForce` mover is needed yet — that layer only
becomes necessary once WallRun/ClimbVault/etc. are built.

States still never touch Roblox physics APIs directly — always through
`CharacterMover`'s narrow interface (`SetSpeed`, `RequestJump`, `Disable`). This
keeps the door open to swapping in the custom mover later without rewriting these
states.

**Facing:** `Humanoid.AutoRotate = false`. `FacingController` aligns the root part to
the camera/aim direction every frame, independent of whichever locomotion state is
active. `LocomotionAnimator` reads the angle between facing and movement direction to
pick the right one of the 8 directional blends. Facing rides on the character's
normal replicated `CFrame`, so it needs no dedicated network event.

---

## 5. Client/Server Model

Idle, Walk, and Airborne carry no earned condition, so they need no remote: Humanoid
state (WalkSpeed, jump, fall) already replicates natively, and
`MovementValidationService` mirrors those transitions passively from that
replication plus a lightweight max-speed/delta-position sanity check
(anti-noclip/speed-hack net) that owns `WalkSpeed` as the ground-truth cap per tier.

`Run` and `Sprint` are earned transitions and the real exploit surface — a modified
client could claim either without ever earning it — so they're the ones that need an
explicit network signal.

**Resolved 2026-09-13 — the remote:** `RequestMovementTransition` in `network.zap`,
`Client -> Server`, payload `enum { "Run", "Sprint" }` (deliberately scoped to only
these two values, not the full 5-state set — Zap's own type validation then rejects
any other claim before it reaches handler logic at all). The server **never** trusts
a client-sent timestamp for the dwell check — it validates the claim against its own
`MovementValidationService` entry-timestamp for when *it* observed the player enter
`Run`, same lag-compensation principle as parry (`docs/ARCHITECTURE.md` §4), just
applied to a locomotion transition instead of a parry window.

**Known gap — rate limiting:** `docs/ARCHITECTURE.md` §5/§10 describe rate limits as
"declared on the event in `network.zap`." Verified against Zap's own docs
(`zap.redblox.dev/config/events`, `/config/options.html`) on 2026-09-13: **Zap has no
native per-event rate-limit field** — only `from`/`type`/`call`/`data`. Since the
architecture rule's actual intent is a rate limit "independent of any FSM cooldown,"
not literally a Zap syntax feature, this is satisfied by a shared utility instead:
`Shared/Util/RateLimiter.luau` (added 2026-09-13) — a fixed-size sliding-window
gate (`RateLimiter.new(maxCalls, perSeconds):tryAcquire() -> boolean`), evaluated
against `zap.redblox.dev` and third-party alternatives (see below) before writing
it. Excess calls are dropped, never queued — for a security gate, delaying and
later executing an exploiter's spam is worse than dropping it outright. It holds no
connections or scheduled threads, so it needs no `Trove`/`destroy()`.

**Considered and rejected:** the third-party `krazeems/RateManager` (Wally:
`kareemmarzouk/ratemanager`, note the README's own install snippet has the wrong
Wally scope). Its sliding-window algorithm is correct, but `Destroy()` doesn't
cancel in-flight `task.delay` threads — a pending call's delayed closure can still
fire after `Destroy()` and error trying to `:Fire()` a nil'd-out signal, which is
exactly our per-player-limiter-destroyed-on-leave scenario. It also bundles its own
`signal.lua` instead of this project's standard `LemonSignal`, and ships `--!nocheck`
instead of `--!strict`. Not adopted; `RateLimiter.luau` above avoids the whole bug
class by having no background timers or signals to leak in the first place.

`RequestMovementTransition` doesn't call `RateLimiter` yet — that lands with
`MovementValidationService` in Step 2, instantiated per-player at
`~5 calls/sec` (exact constant TBD when that service is built), independent of the
state's own FSM cooldown.

---

## 6. Implementation Steps

1. **Shared scaffolding** — ✅ done 2026-09-13. `MovementStates` Symbols
   (Idle/Walk/Run/Sprint/Airborne), extended `StateMachine.luau`,
   `MovementConstants` (tap-window + sprint-threshold constants only — speed/jump
   tiers deliberately deferred to Step 2 rather than guessed now), `MovementTypes`,
   `StateRules` (CanEnter predicates + transitions topology), `network.zap`
   (`RequestMovementTransition`).
2. **Core states** — all five state modules on the Humanoid-driven path,
   `InputController` → Intent pipeline including the W double-tap detector,
   `RunState`'s dwell-timer/self-transition into Sprint, `MovementController` wiring,
   server `MovementValidationService` mirror skeleton with entry-timestamp tracking.
   This is also where `WalkSpeed`/`RunSpeed`/`SprintSpeed`/`JumpPower` get real,
   playtested values in `MovementConstants` — not guessed ahead of time.
3. **Facing + animation** — `FacingController` (camera-relative, `AutoRotate` off),
   then `LocomotionAnimator` wiring the 8 directional blends against it.
4. **Exploit + perf pass** — server-side speed/delta-position sanity check audit,
   the Sprint-timestamp legality check specifically, the rate-limit gap above,
   `Trove` audit, `os.clock()` audit.

---

## 7. Optimization Standards

- `os.clock()` exclusively for all movement timing math — never `tick()`, including
  the double-tap window and the Run→Sprint dwell timer.
- Every `MovementController`/FSM instance owns exactly one `Trove`;
  `Trove:Destroy()` once on the cleanup boundary (death/respawn), fresh `Trove` for
  the next life. `LocomotionAnimator`'s loaded `AnimationTrack`s go through this same
  Trove — no separately-tracked cleanup path for animation instances.
- Strict Luau typing (`--!strict`) throughout so state `Enter`/`Update`/`Exit`
  signature drift fails at compile time, not at runtime.
- Zero magic numbers — every tunable value (including tap window and sprint
  threshold) lives in `MovementConstants.luau`. Numbers only go in once they're a
  real tuning decision, never as a scaffold placeholder (see commit `a31e6d9` —
  placeholder speed/jump values were deliberately stripped from this file once
  already; don't reintroduce guessed numbers).
- Cosmetic-only replication (facing/animation-relevant data, if any needs sending at
  all beyond default `CFrame` replication) is throttled, not sent every Heartbeat.

---

## Deferred (designed earlier, not part of this build)

- **WallRun / ClimbVault / LedgeGrab / Slide** — spatial-claim states needing a
  custom `LinearVelocity`/`VectorForce` mover layer, throttled sanity raycasts, and a
  full predict-then-validate-with-lag-compensation network loop per transition.
- **Qinggong / stamina resource** — gates those four states only, never Walk/Run/
  Sprint. Server-owned like a cooldown: client predicts locally for UI, server drains
  on use and regens, reconciles the client's copy. Worth deciding when you get here:
  your architecture doc already names `Qi` as a custom profile value alongside HP and
  posture — is Qinggong the *same* Qi pool combat abilities will spend later, or a
  separate movement-only resource? Not a decision this doc needs to make yet.
- **`Overridden` state** — the single narrow seam combat will later use to move the
  character (e.g. for Dash) without touching movement's FSM directly.

Ask for the full spec on any of these when you're ready to build them.
