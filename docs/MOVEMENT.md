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
| Shared scaffolding (Step 1) | Done — 2026-09-13 | `Shared/FSM/MovementStates.luau`, `Shared/FSM/StateMachine.luau`, `Shared/Constants/MovementConstants.luau`, `Shared/Types/MovementTypes.luau`, `Shared/Movement/StateRules.luau`, `network.zap`, `Shared/Util/RateLimiter.luau` |
| Core states (Step 2) | Done — 2026-09-13 | `Client/Controllers/Movement/{init,CharacterMover,InputController,ClientMovementContext}.luau`, `Client/Controllers/Movement/States/*.luau`, `Server/Services/MovementValidationService.luau` |
| Facing + animation (Step 3) | Logic done 2026-09-13, **animations still needed** | `Client/Controllers/Movement/Presentation/{FacingController,LocomotionAnimator}.luau`, `Shared/Constants/MovementAnimations.luau` |
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
   -> FSM:RequestTransition(state, context)                [Symbol-keyed, legality-checked]
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

fsm:RequestTransition(next, context) -> boolean
-- Rejects next == current outright (a self-loop isn't a real transition), then
-- checks adjacency AND (if present) rules[next](context) before transitioning.
-- Returns false and does nothing if any check fails.

fsm:CanTransition(next, context) -> boolean  -- same checks, no side effect
fsm:Destroy()                                -- Trove:Destroy(), disconnects `changed`
```

Methods are `PascalCase` (`RequestTransition`, not `requestTransition`) to match `Trove`/
`LemonSignal`/`Loader` and every native Roblox `Instance` method, per `ARCHITECTURE.md`
§7 — the original scaffolded file used `camelCase` methods, which was inconsistent with
the rest of the codebase it composes (`self._trove:Add(...)` next to `self:destroy()`);
fixed 2026-09-13, before any consumer existed to migrate.

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
  `FSM:RequestTransition(Sprint, context)`. This is a state timing itself into the
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

- **Airborne landing** (resolved 2026-09-13, refined while building Step 2):
  `AirborneState.Update` checks currently held input and transitions straight into
  `Idle` or `Walk` — never through an intermediate `Idle` frame first, and **never
  directly into `Run`, even if forward is held**. Two refinements versus the
  original resolution: (1) the decision lives in `Update`, not `Exit` — by the time
  `Exit` runs for the state being left, `StateMachine:RequestTransition` has already
  committed `fsm.current` to the next state before firing `changed` (see §1's engine
  API), so `Exit` can only ever be teardown, never the thing choosing where to land;
  (2) landing never restores `Run` directly, because `Run.CanEnter` is just
  `grounded and hasMoveInput` — identical to `Walk`'s — so the double-tap gesture
  isn't encoded in `CanEnter` at all, only in *who calls* `RequestTransition(Run,
  ...)` (exclusively `InputController`'s double-tap detector). If landing also
  attempted `Run` on held input, jumping-and-landing-while-holding-W would silently
  grant `Run` without ever double-tapping. `Sprint` was already correctly
  unreachable from landing (has to be earned fresh via a new dwell in `Run`) and
  still is.

**Bug fixed 2026-09-13 — Sprint dead end:** `Sprint`'s topology originally only
listed `{Run, Airborne}` as reachable targets. A player who released all movement
input while sprinting but stayed grounded (no jump) had no legal way out: `Run`'s
edge failed `CanEnter` (no move input), `Airborne`'s edge failed `CanEnter` (still
grounded), and `Idle` wasn't in the edge list to even attempt. `RequestTransition`
returned `false` for every target — the FSM stuck in `Sprint` until the player
jumped. Fixed by adding `Idle` to `Sprint`'s `Transitions` entry in
`StateRules.luau`, matching every other grounded state's edge list. `Walk` was
deliberately **not** added alongside it: `Walk.CanEnter` and `Run.CanEnter` are
currently the identical predicate (`grounded and hasMoveInput`), so any input still
held on Sprint's exit already resolves via the existing `Run` edge — adding `Walk`
too would be inert redundancy, not additional coverage, unless those two predicates
diverge later.

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
    MovementAnimations.luau   -- AnimationId slots for LocomotionAnimator, all nil
                                  until real animations are uploaded (Step 3)
  Types/
    MovementTypes.luau        -- strict type defs: MoveIntent, MovementContext, etc.
  Movement/
    StateRules.luau           -- CanEnter() legality predicates + the ladder's
                                  transitions topology, shared client/server
  Util/
    RateLimiter.luau          -- generic sliding-window rate gate, not movement-
                                  specific but added alongside Step 1 for it

Client/Controllers/
  Movement/
    init.luau                    -- MovementController: Init entry point, owns the
                                     FSM instance + per-life Trove
    InputController.luau         -- raw input -> Intent; owns the W double-tap detector
    CharacterMover.luau           -- narrow physics interface states call into
    ClientMovementContext.luau    -- client-only context type (Shared MovementContext
                                      + characterMover/fsm); its own leaf module so
                                      init.luau and States/* can both depend on it
                                      without requiring each other
    States/
      IdleState.luau
      WalkState.luau
      RunState.luau               -- owns the Run->Sprint dwell timer and self-transition
      SprintState.luau
      AirborneState.luau
    Presentation/                 -- purely cosmetic, never touched by states or FSM
      FacingController.luau       -- aligns character orientation to camera/aim each
                                      frame, fully decoupled from movement direction;
                                      done 2026-09-13, no external assets needed
      LocomotionAnimator.luau     -- picks/blends among the 8 directional Walk/Run
                                      anims from (facing-relative input angle, current
                                      state); reads the FSM and InputController, writes
                                      to neither; logic done 2026-09-13, waiting on
                                      real AnimationIds in MovementAnimations.luau

Server/Services/
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
the right folder, **with one caveat found while building Step 2**: `LoadChildren`
only requires **direct** children of `Controllers`/`Services`, never descendants. A
system with only one file (`MovementValidationService.luau`) can sit flat under
`Services/` and just works. A system with private helper modules (`Movement`, with
its `InputController`/`CharacterMover`/`ClientMovementContext`/`States/`) has to use
Rojo's `init.luau` convention — the folder becomes the ModuleScript itself, and its
sibling files become real children reachable via `script.X` — otherwise everything
under that subfolder is invisible to `LoadChildren` and silently never gets `Init`'d
(no error, the game just boots with that system doing nothing). Use `init.luau`
whenever a controller/service needs private helper modules; a flat `<Name>.luau` is
correct when it's self-contained.

---

## 4. Physics Model

All five Phase 1 states drive off `Humanoid.WalkSpeed`/`JumpPower`, sourced from
`MovementConstants` (one speed constant per ladder tier). No custom
`LinearVelocity`/`VectorForce` mover is needed yet — that layer only becomes
necessary once WallRun/ClimbVault/etc. are built.

States still never touch Roblox physics APIs directly — always through
`CharacterMover`'s narrow interface.

**Scope narrowed while building Step 2 (2026-09-13):** the original design listed
`SetSpeed`/`RequestJump`/`Disable` as `CharacterMover`'s interface. Only `SetSpeed`
(plus a read-only `IsGrounded`) actually got built. Reasoning: Roblox's default
character-control scripts (the stock `PlayerModule`/`ControlModule`, untouched by
this project) already turn WASD into `Humanoid:Move()` and Space into a jump,
honoring `Humanoid.WalkSpeed`/`JumpPower` automatically — none of Phase 1's five
states need to call `Humanoid:Move()` or trigger a jump themselves, only to set
which `WalkSpeed` tier is active and read whether the Humanoid is currently
grounded. `RequestJump`/`Disable` would have had zero callers this phase (Airborne
is entered *reactively*, by observing the Humanoid's own state change, never by a
state commanding a jump). Left out rather than added as unused no-ops, per this
codebase's own "don't design for hypothetical future requirements" rule — add them
when a real caller exists (e.g. a future forced-launch/stun state), not
speculatively now. `AutoRotate = false`, `UseJumpPower = true`, and `JumpPower` are
all set once in `CharacterMover.new`.

**Facing:** `Humanoid.AutoRotate = false`. `FacingController` aligns the root part to
the camera/aim direction every frame, independent of whichever locomotion state is
active. `LocomotionAnimator` reads the angle between facing and movement direction to
pick the right one of the 8 directional blends. Facing rides on the character's
normal replicated `CFrame`, so it needs no dedicated network event.

**Built 2026-09-13 (Step 3), logic complete but not yet animatable:**
`FacingController` runs on `RenderStepped`, flattens the camera's `LookVector` to the
XZ plane, and sets `rootPart.CFrame = CFrame.lookAt(position, position + flatLook)`
every frame — no dependency on `LocomotionAnimator` or vice versa, both just read
the same `rootPart.CFrame` independently. `LocomotionAnimator` computes the signed
angle between that facing vector and the current `MoveIntent.direction` (via
`Vector3:Cross`/`:Dot`, `math.atan2`), buckets it into one of the 8 named directions
(45° wide, centered on Forward/ForwardRight/.../ForwardLeft), and maps
`(state, bucket)` to a track key into `MovementAnimations.luau`.

Two scoping calls worth flagging:
- **Discrete switch-with-crossfade, not a real blend space.** "Picks/blends among
  the 8 directional anims" is implemented as: stop whatever's playing, `Play(0.15)`
  the new bucket's track. Not a weighted multi-track blend tree. Revisit once real
  animations exist and playtesting shows whether a hard bucket switch (even
  crossfaded) reads as too abrupt between adjacent directions.
- **No Airborne animation yet.** Neither the original design nor this pass defines
  a jump/fall clip — `LocomotionAnimator` fades out whatever was playing and does
  nothing else while Airborne. Add a slot to `MovementAnimations.luau` and a branch
  in `LocomotionAnimator:_update` once one exists; not a blocker for anything else.

**Still needed before this is visible in-game:** `MovementAnimations.luau` ships
with every `AnimationId` slot `nil` — no assets exist yet (2026-09-13). Same
"don't guess placeholder values" rule as `MovementConstants` (commit `a31e6d9`):
`LocomotionAnimator` skips loading/playing any `nil` slot, so the code runs
correctly with zero animations playing rather than erroring, but nobody will see
directional locomotion until real `Walk`/`Run`/`Sprint`/`Idle` AnimationIds are
filled in.

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

**Wired in Step 2 (2026-09-13):** `MovementValidationService` creates one
`RateLimiter.new(5, 1)` per player session (`TRANSITION_CLAIMS_PER_SECOND`, a
network-layer constant that lives in the service itself, not `MovementConstants` —
that file is gameplay tuning, this is an anti-spam limit). Every
`RequestMovementTransition` call checks `rateLimiter:tryAcquire()` before touching
the FSM at all; a limited call is dropped silently, never queued.

The service keeps one `PlayerSession` per player: a server-side FSM mirror built
from the exact same `StateRules.Transitions`/`CanEnter` the client uses, the
`RateLimiter`, and `runEnteredAt` (server's own `os.clock()` timestamp for when *it*
accepted a Run claim — never anything the client sends). `Idle`/`Walk`/`Airborne`
are mirrored passively every Heartbeat straight off `Humanoid:GetState()` and
`Humanoid.MoveDirection`; `Run`/`Sprint` are only ever entered through the explicit
claim handler, so an unclaimed client can never end up mirrored as either no matter
what its `MoveDirection` says.

**Known simplification:** the server has no per-axis input (only
`Humanoid.MoveDirection`'s aggregate vector), so it can't replicate the client's
exact Sprint→Run backpedal rule (§2) — a player who strafes without backpedaling
could, in principle, leave the server mirror in `Sprint` a moment longer than the
client's own local state. This isn't a real gap in practice: the client re-fires
`RequestMovementTransition("Run")` on *every* transition into `Run`, including this
one (`init.luau`'s `changed` handler fires the claim for any transition landing on
`Run`, not just the double-tap path), which corrects the server's mirror via the
same validated path a moment later. Revisit if Step 4's speed/delta-position sanity
check ever needs the mirror to be exact rather than eventually-consistent.

---

## 6. Implementation Steps

1. **Shared scaffolding** — ✅ done 2026-09-13. `MovementStates` Symbols
   (Idle/Walk/Run/Sprint/Airborne), extended `StateMachine.luau`,
   `MovementConstants` (tap-window + sprint-threshold constants only — speed/jump
   tiers deliberately deferred to Step 2 rather than guessed now), `MovementTypes`,
   `StateRules` (CanEnter predicates + transitions topology), `network.zap`
   (`RequestMovementTransition`).
2. **Core states** — ✅ done 2026-09-13. All five state modules
   (`Client/Controllers/Movement/States/*.luau`), each aliasing its `CanEnter` from
   `StateRules.CanEnter` rather than redeclaring it (single source of truth, no
   drift risk); `InputController`'s W double-tap detector and camera-relative
   `MoveIntent` resolution; `RunState`'s dwell-timer/self-transition into Sprint;
   `MovementController` (`Client/Controllers/Movement/init.luau`) wiring the FSM,
   per-life `Trove`, and `changed`-driven `Enter`/`Exit` dispatch; server
   `MovementValidationService` with real entry-timestamp tracking and `RateLimiter`
   wired in (not just a skeleton). `WalkSpeed`/`RunSpeed`/`SprintSpeed`/`JumpPower`
   got real starting values in `MovementConstants` ("Fast & fluid" preset — Walk 18
   / Run 28 / Sprint 40 / JumpPower 55 — chosen by the user, not guessed; still a
   starting point for in-Studio tuning, not a final pass).
3. **Facing + animation** — ✅ logic done 2026-09-13, **⚠️ needs real
   AnimationIds before it's visible in-game**. `FacingController` (camera-relative,
   `AutoRotate` off) and `LocomotionAnimator` (8-directional bucket selection +
   crossfade, reading `MovementAnimations.luau`) are both built per §4. No Airborne
   clip yet, and blending is a discrete crossfade, not a true blend space — see §4
   for why. `MovementAnimations.luau` ships with every slot `nil`; fill in real
   Walk/Run/Sprint/Idle AnimationIds once those animations are uploaded.
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
