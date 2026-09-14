# Movement System

Living design + implementation doc for the movement FSM. Update this as states get
built, decisions change, or numbers get tuned — this is not a one-time spec.

**Active build scope (Phase 1): Idle, Walk, Run, Sprint, Airborne (jump + fall).**
None of these five are gated by stamina/Qinggong — that resource only matters for
WallRun/ClimbVault/LedgeGrab/Slide, which aren't built yet. See **Deferred** at the
bottom for a pointer, not a full spec.

Movement is **strafe-style while the camera is locked to the character** (Shift
Lock or first-person): facing decouples from movement direction, you face wherever
the camera/aim points, and input direction relative to that facing selects among
your 8 directional animations. In normal free-orbit third-person (not locked), the
character auto-faces movement direction like default Roblox — see §4's Facing
section, corrected 2026-09-13. Target feel: fast and fluid, momentum-preserving,
generous air control.

## Implementation Status

| Piece | State | Files |
|---|---|---|
| Shared scaffolding (Step 1) | Done — 2026-09-13 | `Shared/FSM/MovementStates.luau`, `Shared/FSM/StateMachine.luau`, `Shared/Constants/MovementConstants.luau`, `Shared/Types/MovementTypes.luau`, `Shared/Movement/StateRules.luau`, `network.zap`, `Shared/Util/RateLimiter.luau` |
| Core states (Step 2) | Done — 2026-09-13 | `Client/Controllers/Movement/{init,CharacterMover,InputController,ClientMovementContext}.luau`, `Client/Controllers/Movement/States/*.luau`, `Server/Services/MovementValidationService.luau` |
| Facing + animation (Step 3) | Logic done 2026-09-13, **animations still needed** | `Client/Controllers/Movement/Presentation/{FacingController,LocomotionAnimator}.luau`, `Assets/Animations/Movement.model.json` |
| Exploit + perf pass (Step 4) | Done — 2026-09-13 | `Server/Services/MovementValidationService.luau`, `Shared/Util/ViolationTracker.luau`, `Shared/Constants/MovementConstants.luau` |

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

**Bug fixed 2026-09-13 — Sprint never returned to Idle on a full stop.**
`SprintState.Update` only ever attempted `Sprint -> Run` when `forward` went false,
reasoning that `RunState.Update` would demote to `Idle` on the next frame if input
was truly zero. That reasoning was wrong: `Run.CanEnter` itself requires nonzero
move input, so releasing every key and attempting `Sprint -> Run` directly **fails
`CanEnter`** — the transition never happens, and the FSM was stuck in `Sprint`
indefinitely (only a jump, via the `Airborne` edge, could get out). Fixed by
checking `not StateRules.HasMoveInput(context)` first and attempting `Idle`
directly in that case, before the `forward` check — `Run` is only attempted when
there's still *some* input (backpedal/strafe) for it to legally accept. The
server's `MovementValidationService` mirror was never affected: its passive
mirroring already attempted `Idle` directly whenever `Walk`/`Run`/`Sprint` had no
input left, so this was a client-only bug.

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
Assets/Animations/
  Movement.model.json         -- Rojo-synced Animation instance tree: Idle/Run/Sprint
                                  (single clips) plus Walk/{8 directions}, every
                                  AnimationId blank until real animations exist --
                                  mounted at ReplicatedStorage.Assets.Animations.Movement

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
      LocomotionAnimator.luau     -- picks/blends among Walk's 8 directional anims
                                      (facing-relative input angle) or Idle/Run/
                                      Sprint's single clip, from current state; reads
                                      the FSM and InputController, writes to neither;
                                      logic done 2026-09-13, waiting on real
                                      AnimationIds in Assets/Animations/Movement.model.json

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
speculatively now. `UseJumpPower = true` and `JumpPower` are set once in
`CharacterMover.new`. `AutoRotate` is *not* set here — see Facing below.

**Facing:** `AutoRotate` is toggled per-frame by `FacingController`, not forced
permanently off (corrected 2026-09-13 — see the dated entry below). `FacingController`
aligns the root part to the camera/aim direction only while the camera is actually
locked to the character; otherwise `Humanoid`'s own `AutoRotate` takes over so
free-orbiting the camera doesn't drag the character's facing with it. `LocomotionAnimator`
reads the angle between current facing and movement direction to pick the right one
of the 8 directional blends — this needs no special-casing for the unlocked case,
since `AutoRotate` naturally keeps facing ≈ movement direction there, which just
resolves to the `Forward` bucket. Facing rides on the character's normal replicated
`CFrame`, so it needs no dedicated network event.

**Built 2026-09-13 (Step 3), logic complete but not yet animatable:**
`FacingController` runs on `RenderStepped`, flattens the camera's `LookVector` to the
XZ plane, and sets `rootPart.CFrame = CFrame.lookAt(position, position + flatLook)`
every frame — no dependency on `LocomotionAnimator` or vice versa, both just read
the same `rootPart.CFrame` independently. For `Walk` specifically, `LocomotionAnimator`
computes the signed angle between that facing vector and the current
`MoveIntent.direction` (via `Vector3:Cross`/`:Dot`, `math.atan2`), buckets it into one
of the 8 named directions (45° wide, centered on Forward/ForwardRight/.../ForwardLeft),
and maps `(state, bucket)` to a track key. `Idle`/`Run`/`Sprint` each map to a single,
non-directional track key regardless of facing-relative angle.

Two scoping calls worth flagging:
- **Discrete switch-with-crossfade, not a real blend space.** Walk's "picks/blends
  among the 8 directional anims" is implemented as: stop whatever's playing,
  `Play(0.15)` the new bucket's track. Not a weighted multi-track blend tree.
  Revisit once real animations exist and playtesting shows whether a hard bucket
  switch (even crossfaded) reads as too abrupt between adjacent directions.
- **No Airborne animation yet.** Neither the original design nor this pass defines
  a jump/fall clip — `LocomotionAnimator` fades out whatever was playing and does
  nothing else while Airborne. Add a slot to the model below and a branch in
  `LocomotionAnimator:_update` once one exists; not a blocker for anything else.

**Bug fixed 2026-09-13 — Walk directional buckets were left/right-mirrored.**
`resolveDirectionBucket` computed `cross = flatFacing:Cross(flatMove)`, but Roblox's
`Cross` follows the right-hand rule, and that operand order gives the sign for
rotating *from* facing *to* move-direction — backwards from the "positive angle =
clockwise = Right" convention the bucketing math assumes. Concretely: facing
`(0,0,-1)` (Roblox's default forward) with `moveDirection = (1,0,0)` (world +X, your
right hand when facing that way) resolved to `"Left"` instead of `"Right"`. Forward
and Back were unaffected — parallel and anti-parallel vectors cross to zero
regardless of operand order — which is exactly why walking looked like it "worked"
while every lateral and diagonal bucket played mirrored. Fixed by swapping to
`flatMove:Cross(flatFacing)`. Worth a quick playtest once real Walk animations are
in to confirm Right/Left/the four diagonals all read correctly now, since this
couldn't be verified without live assets. **Not the root cause reported
2026-09-13** ("anims fighting with Roblox's native animations") — see the next
entry for that.

**Bug fixed 2026-09-13 — custom animations were fighting Roblox's default
`Animate` script.** Roblox auto-adds an `Animate` LocalScript to every character,
which plays its own walk/idle/jump animations on the *same* `Humanoid`/`Animator`
automatically based on `MoveDirection`/state, entirely independent of
`LocomotionAnimator`. Left in place, both systems play tracks on the same rig
simultaneously — visible as animations flickering/fighting each other, which
matches what was reported. `LocomotionAnimator.new` now destroys the character's
`Animate` script (`humanoid.Parent:FindFirstChild("Animate")`) the moment it takes
over, every life. **Side effect worth flagging:** the default `Animate` script also
covers default tool-holding, sitting, swimming, and climbing animations — none of
which this project uses yet (R6, no tools/combat built), so losing them isn't a
regression today, but whoever builds tool-equip or combat animations later will
need to handle those explicitly rather than relying on the default script, since
it's gone for good on any character this system manages.

**Bug fixed 2026-09-13 — camera-facing was forced even outside Shift Lock.**
`FacingController` originally forced the character to face the camera every frame
unconditionally, and `CharacterMover` forced `Humanoid.AutoRotate = false`
permanently — so rotating the camera in normal free-orbit third-person (not
Shift Locked, not first-person) dragged the character's facing along with it,
instead of the character auto-facing movement direction like default Roblox
third-person. Fixed by making both conditional on
`UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter`, which Roblox
sets for both Shift Lock and first-person camera (the only reliable signal for
"camera is locked to the character" without reaching into the default
`PlayerModule`'s internal state, which isn't stable API). `FacingController` now
toggles `Humanoid.AutoRotate` itself each frame — `true` when unlocked (Roblox's
own physics rotates the character to face movement direction, same as default
third-person), `false` plus an active camera-facing override when locked (the
original strafe-style behavior). `CharacterMover` no longer touches `AutoRotate`
at all. This required changing `FacingController.new`'s signature to take
`humanoid` in addition to `rootPart`.

Originally assumed no `LocomotionAnimator` change was needed here — reasoning that
unlocked, `AutoRotate` keeps facing chasing movement direction, so
`resolveDirectionBucket` would naturally resolve to `Forward` "almost all the time."
That "almost" was the problem — see the next entry.

**Bug fixed 2026-09-13 — Walk stuttered while turning unlocked.** `AutoRotate`
doesn't snap the character's facing to the movement direction instantly, it swings
toward it gradually. While unlocked and mid-swing, the angle between facing and
movement direction sweeps through several of the 8 buckets in quick succession
(e.g. Right → ForwardRight → Forward as the character turns to catch up) — and
`LocomotionAnimator:_playKey` stops/crossfades to a new track on every single bucket
crossing, which reads as the walk animation stuttering/restarting whenever WASD
input changes direction. Fixed by only computing the directional bucket at all when
`UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter` (same signal
`FacingController` uses) — unlocked, `Walk` always plays the `Forward` clip
outright, skipping `resolveDirectionBucket` entirely, since there's nothing
meaningful to bucket when you're always facing where you walk by definition. Locked,
facing is genuinely decoupled from movement again (snapped directly to the camera
every frame, not swung gradually) and the full 8-directional set is meaningful, same
as originally designed.

**Resolved 2026-09-13 — Run is not directional.** Corrected after Step 3 first
shipped Run as an 8-directional set mirroring Walk: Run only ever has one
animation, played regardless of facing-relative angle. Both
`Assets/Animations/Movement.model.json` (Run is a single `Animation` instance, not
a folder of 8) and `LocomotionAnimator` (Run maps straight to a `"Run"` key,
skipping `resolveDirectionBucket` entirely) were updated to match. Only `Walk`
remains directional.

This is a **temporary animation-pass simplification, not a structural equivalence
to `Sprint`** (corrected 2026-09-13 — the original wording here claimed "same as
Sprint," which overstates it): `Sprint`'s forward-bias is *actively enforced* —
`SprintState.Update` demotes to `Run` on backpedal or pure strafe, and (as of the
server-side fix above) `MovementValidationService` now enforces that same demotion
independently. `Run.CanEnter` has no directional restriction at all — it's
identical to `Walk`'s (`grounded and hasMoveInput`), and nothing demotes out of
`Run` based on movement direction. The single-clip treatment here is purely because
no real animations exist yet either way, not because Run and Sprint share a
gameplay rule. If Run ever gets a real forward-only demotion rule of its own,
that's a separate gameplay-feel decision — not implied by this entry.

**Resolved 2026-09-13 — real instances, not a data-table duplicate.** Originally
built as `Shared/Constants/MovementAnimations.luau`, a plain Luau table of
`AnimationId` strings, with `LocomotionAnimator` building a throwaway
`Instance.new("Animation")` per slot at runtime. Replaced same-day with
`Assets/Animations/Movement.model.json`, a Rojo-synced instance tree mounted at
`ReplicatedStorage.Assets.Animations.Movement` (`Idle`/`Run`/`Sprint` single
Animation instances, plus a `Walk` folder holding the 8 directional Animation
children). Reasoning: this matches the project's existing "hand-authored content
lives as instances, scripts only `WaitForChild` into it" philosophy (`docs/ARCHITECTURE.md`
§8's GUI rule, applied here to animations) without losing version control — the
`.model.json` is a plain text file that diffs and reviews normally, same as any
`.luau` file, while still letting someone set real `AnimationId`s from Studio's
property panel rather than editing Luau source. `LocomotionAnimator.loadTrack` now
does `container:WaitForChild(name, 1)` (short timeout, never an indefinite block)
and treats a missing child *or* a found one with a blank `AnimationId` as "not
authored yet" — same graceful no-op as the old `nil`-string check, just checking an
Instance property instead of a table value. Verified against the real `rojo` CLI
(`rojo build`) that the `.model.json` schema (`ClassName`/`Name`/`Properties`/
`Children`, no `$`-prefixes — that prefix form is only for inline trees directly
inside `default.project.json`) produces exactly the intended tree before writing
any of the consuming code.

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

**Exploit fixed 2026-09-13 — Sprint's backpedal demotion is now enforced
server-side, not assumed via the client's reclaim.** This used to be written up as
a "known simplification": the server had no per-axis input, only
`Humanoid.MoveDirection`'s aggregate vector, so it couldn't replicate
`SprintState.Update`'s exact backpedal/pure-strafe demotion — the stated reasoning
was that this was fine because the client re-fires `RequestMovementTransition("Run")`
on every transition into `Run`, correcting the server's mirror "a moment later."

That reasoning only holds for a well-behaved client. It does not hold against the
threat model `docs/ARCHITECTURE.md` §3 ("The Client Is a Liar") is built around: a
modified client has no obligation to ever send that reclaim. Left as-is, a hacked
client could earn `Sprint` once and then hold it indefinitely in any direction —
including standing in place with trivial nonzero input — since nothing server-side
ever re-checked the demotion condition on its own initiative.

Fixed by giving `MovementValidationService` real geometric intent classification
instead of hardcoded `false`s: `buildContext` now derives `forward`/`backward`/
`strafeLeft`/`strafeRight` from the sign of `rootPart.CFrame.LookVector`'s dot/cross
product with `humanoid.MoveDirection` (`classifyMoveIntent`, same sign convention as
`LocomotionAnimator.resolveDirectionBucket`) — both server-trusted replicated state,
not anything the client asserts. `mirrorPassiveTransitions` then actively demotes
`Sprint -> Run` on the server's own initiative, every Heartbeat, whenever that
classification says `forward` is false — the same condition `SprintState.Update`
uses client-side, just computed from a different (server-trustworthy) signal, since
raw WASD key state itself never replicates. This is additive: the existing
"no input at all -> Idle" and "not grounded -> Airborne" branches are unchanged.

**Exploit fixed 2026-09-13 — the server-side Sprint demotion above didn't reset
`runEnteredAt`, so a client that skipped the "Run" reclaim could instantly
re-earn Sprint.** `RunState.Enter` resets the client's own dwell clock on *every*
entry into `Run`, including landing there via a `Sprint` backpedal demotion — a
legitimate client can never regain `Sprint` without a fresh, uninterrupted 3
seconds in `Run`, no matter how it got there. The server-side demotion added
above didn't mirror that: it moved `session.fsm.current` back to `Run` but left
`session.runEnteredAt` untouched, still holding the timestamp from *before*
`Sprint` was ever entered. A modified client that claims `Sprint` again shortly
after being demoted — skipping the "Run" reclaim a well-behaved client always
sends — would have its `runDuration` computed against that stale timestamp and
pass the dwell check instantly, off elapsed time it never actually spent
continuously in `Run`. Fixed by resetting `session.runEnteredAt = os.clock()`
at the moment the server-side demotion succeeds, matching `RunState.Enter`'s
own behavior exactly.

**Resolved 2026-09-13 — the promised speed/delta-position sanity check is now
built.** §5 always described this as part of the client/server model, but Steps
1–3 never actually implemented it — `MovementValidationService` only mirrored FSM
*legality*, with no check on the character's actual physical movement at all. A
classic speed hack (setting `Humanoid.WalkSpeed` directly, bypassing the FSM and
`RequestMovementTransition` entirely) would have gone completely undetected.
Fixed with `enforceSpeedSanity`, run once per session every Heartbeat but
internally throttled to fire only every `MovementConstants.SpeedCheckIntervalSeconds`
(0.5s) — sampling every raw Heartbeat was tried first and rejected, because a
network-owning client's `CFrame` replicates to the server in bursts, not evenly
per frame, so a frame-to-frame delta false-positived on ordinary replication
jitter well before it caught anything real. Horizontal (`X`/`Z`) displacement over
that interval is compared against `maxSpeedForState(session.fsm.current) * elapsed
* MovementConstants.SpeedToleranceMultiplier` (1.3x grace for the same jitter plus
latency) — deliberately keyed off the **server's own mirrored FSM state**, never
`humanoid.WalkSpeed` as reported, since that property is exactly what a speed hack
overwrites. `Airborne` has no tier of its own (`AirborneState.Enter` is a no-op —
whatever speed was active at takeoff carries into the jump), so it's capped at
the ceiling (`SprintSpeed`) rather than guessing which tier the player jumped
from. Vertical motion is excluded entirely — this check has no business policing
gravity. A violation snaps the root part's horizontal position back to the last
sampled one (rotation and current height preserved) — a rubber-band correction,
not a kick or a log; revisit if repeated corrections turn out to need a stronger
response (e.g. actually kicking repeat offenders).

**Fixed 2026-09-13 — constant Sprint rubber-banding, reported in playtesting even
on a low-latency connection.** The entry above justified `SpeedToleranceMultiplier`
(1.3) as "grace for jitter plus latency" with no measurement behind it — exactly
what §9 prohibits. Per that rule, the fix here is **not** a bigger number
(unmeasured evidence for a new one wouldn't be any more valid than for the old
one); it's two structural bugs found by tracing the actual transition/replication
sequence, verified by reasoning rather than a captured playtest (this pass had no
way to run a live client — `SPEED_SANITY_DEBUG_LOGGING` below is exactly the
capture mechanism a future playtest should confirm this with).
- **The FSM mirror could get permanently stuck below the player's real speed.**
  `mirrorPassiveTransitions`'s Sprint→Run demotion fires off a single Heartbeat's
  `classifyMoveIntent` read. But `FacingController`'s own fix (§4) already
  established that facing *deliberately* lags `MoveDirection` whenever
  `Humanoid.AutoRotate` is true (unlocked camera) — Roblox's ground controller
  turns the character to catch up rather than snapping. A player simply looking
  around while holding forward, unlocked, can swing `MoveDirection` past this
  check's forward deadzone (see below) for a few frames with zero backward/strafe
  input at all. Once that misfires, the mirror lands in `Run` — but the **client**
  never demoted (its own forward check is the literal, camera-independent W key,
  never wrong this way) and keeps moving at genuine `SprintSpeed`. Since
  `NETWORK_CLAIM_NAMES` only re-fires a claim when the *client's own* FSM
  transitions, and it never did, the mirror never resyncs back to `Sprint` — every
  `enforceSpeedSanity` sample for the rest of that sprint compares real
  `SprintSpeed` motion against the now-permanently-wrong `RunSpeed` cap, i.e.
  continuous corrections until the player fully stops and re-earns Sprint from
  scratch. Latency-independent by construction, which is why it reproduced on a
  good connection. Fixed by gating that demotion branch on `not
  session.humanoid.AutoRotate` (a plain replicated Humanoid property already
  trusted elsewhere, e.g. by `CharacterMover`/`FacingController` — no new trust
  assumption): this proxy is only asked to answer a question ("is this player
  backpedaling *relative to their facing*") that's only coherent in the first
  place while facing is actually decoupled from movement, i.e. locked — see this
  doc's intro. This narrows enforcement while unlocked, it doesn't remove it: "no
  input at all → Idle" and `enforceSpeedSanity`'s speed cap both still apply
  unconditionally. The one residual, low-severity gap — a modified client could
  hold Sprint's speed cap instead of Run's while moving backward, unlocked,
  without ever backpedal-demoting — is accepted and documented here rather than
  silently left implicit.
- **A transition could still be measured against the wrong cap for one window.**
  Separately, any state change that alters `maxSpeedForState`'s cap (most sharply
  landing from `Sprint`/`Airborne` momentum down into `Walk`) could have part of
  its `SpeedCheckIntervalSeconds` window measured against the *new* cap while the
  Humanoid's ground controller was still decelerating from the *old* speed — a
  real, documented Roblox behavior (WalkSpeed changes are not instant), exactly
  the class of thing §9 says a tolerance is allowed to exist for, except this
  fix doesn't need to quantify how long that transient lasts at all: `createSession`
  now resets `speedCheckPosition`/`speedCheckAt` on every `fsm.changed` firing, so
  no sampling window ever straddles a transition boundary in the first place.

Separately (not part of the rubber-banding fix — this direction, if anything, cuts
the other way against it, which is exactly why the `AutoRotate` gate above was
also necessary): **`classifyMoveIntent`'s forward/backward zero-crossing was too
permissive.** `forwardComponent > 0` let a `MoveDirection` sitting at a razor-thin
positive angle (e.g. 89°) count as "forward" and dodge the Sprint→Run demotion
while moving almost entirely sideways. Real WASD input only ever produces a 0°,
45°, or 90°+ camera-relative angle, so this can only be hit by a spoofed
`MoveDirection`, never a legitimate diagonal hold. Hardened to
`MovementConstants.SprintForwardDeadzone` (0.5, i.e. requiring the angle stay under
60°) — comfortably below `cos 45° ≈ 0.707`, so every real diagonal Sprint-hold is
unaffected. This is a gameplay-feel threshold, not a latency tolerance (§9's
"measured engine behavior" bar targets the *other* kind of number), so it's
reasoned from the fixed geometry of keyboard input rather than a network
measurement. The client's own `SprintState.Update` needed no equivalent change:
its `forward` flag is `InputController`'s literal "is W held" boolean, which by
construction can only ever be exactly 0°/45°/90°+ for real keyboard combos —
mirroring the server's continuous dot-product threshold onto it would reintroduce
the exact `AutoRotate`-lag instability the fix above just closed, for zero benefit
(a raw key press has no "angle" to spoof).

**Added 2026-09-13 — diagnostic capture and a reusable violation log.**
`SPEED_SANITY_DEBUG_LOGGING` (`MovementValidationService.luau`, off by default)
gates three `print`s added for this investigation and kept (not deleted) for
Stage 2's spatial-claim validators to reuse the same approach: every
`enforceSpeedSanity` correction logs the player, mirrored state, `flatDelta`,
`maxDistance`, and `elapsed`; a rate-limited `RequestMovementTransition` call logs
the rejection (ruling the limiter in or out as a cause of dropped legitimate
claims); an accepted `Sprint` claim logs how far its `runDuration` overshot
`SprintThresholdSeconds`, which is exactly the claim-round-trip lag §5 asks to
measure at Sprint entry. Flip it on for the next playtest to get real numbers
instead of another guess. Separately, `Shared/Util/ViolationTracker.luau` (new,
generic — doesn't know anything about movement) gives `enforceSpeedSanity` a
per-player count/timestamp of corrections instead of correcting forever with no
record; not a punishment system, just a log for something to check later, and
built to be reused as-is by WallRun/ClimbVault/LedgeGrab/Slide's validators once
Stage 2 starts.

**Fixed 2026-09-14 — Run→Sprint dwell-clock skew, reproduced regardless of
connection quality.** `RunState.Enter` (client) sets its local dwell clock and
fires the "Run" claim in the same instant, but `session.runEnteredAt` (server)
only starts once that claim actually arrives — some nonzero time later no
matter how good the connection is. The client self-transitions into `Sprint`
locally at exactly local-3.000s and immediately fires the "Sprint" claim; by the
time that reaches the server, its dwell clock (started later) reads right at
the 3.000s boundary rather than comfortably past it, so ordinary jitter had
close to even odds of rejecting that first Sprint claim. This is a *skew* bug,
not a *magnitude* one — it's about landing exactly on the boundary, so it
reproduced identically on a fast connection and a slow one, only the size of
the jitter window differed. Rejected, the mirror stayed in `Run` (the lower
cap) for up to `CLAIM_RESYNC_INTERVAL_SECONDS` while the player was already
genuinely moving at `Sprint` speed, and `enforceSpeedSanity` flagged it —
visually indistinguishable from the 2026-09-13 rubber-banding investigation
above, but a different root cause.

Fixed in `onRequestMovementTransition`'s Run-claim branch: backdate
`session.runEnteredAt` by half this player's measured RTT
(`player:GetNetworkPing() / 2`) instead of stamping raw receipt time — the same
lag-compensation principle `docs/ARCHITECTURE.md` §4 already applies to parry,
compensating with a server-computed estimate, never anything the client
asserts about its own timing. Guarded against `GetNetworkPing()` returning `0`
(no sample yet — e.g. the very first claim right after spawn) or an
implausibly large reading: the backdate is capped at half of this session's
`SprintThresholdSeconds`, so a bad reading here can never backdate far enough
to let `Sprint` be claimed with little to no real `Run` dwell.

**Added 2026-09-14 — landing-momentum grace, a general mechanism (not an
Airborne-specific patch).** Distinct from the 2026-09-13 fix that resets
`enforceSpeedSanity`'s sampling window on every `fsm.changed` (which only ever
fixed windows that straddled a transition boundary, mixing old- and new-tier
motion in one sample). This is a different failure: a window entirely AFTER a
transition, already in the new state, still measuring real residual
momentum — `Humanoid`'s ground controller decelerates toward a lower
`WalkSpeed` target over a real, documented handful of frames rather than
snapping instantly, and that tail can genuinely exceed the new tier's cap for a
moment (most sharply landing from `Sprint`/`Airborne` down into `Walk` while
still holding forward). Exactly the class of thing `docs/ARCHITECTURE.md` §9
permits a tolerance for — "a specific, measured, documented engine behavior" —
so it has to be measured, not guessed.

`PlayerSession` now tracks `previousState`/`lastTransitionAt`, set alongside
the existing baseline reset in `fsm.changed`. A new `effectiveMaxSpeed(session,
constants)` (`MovementValidationService.luau`) compares `maxSpeedForState` for
`previousState` against the current state: if the previous cap was HIGHER and
the transition happened within `LANDING_MOMENTUM_GRACE_SECONDS`,
`enforceSpeedSanity` measures against that higher (previous) cap instead of
snapping to the stricter one immediately — a step function, not a smooth
decay, sized to however long the real transient measured in step 1 below
actually lasts. Keyed generically off **"the cap decreased at the last
transition,"** never off "coming from Airborne" or "going to Walk"
specifically — this is deliberate so Stage 2's WallRun/ClimbVault/LedgeGrab/
Slide, all of which will exit into `Airborne` or `Walk` with their own residual
momentum, get this grace for free the moment their own cap is taught to
`maxSpeedForState`, with no separate copy of this fix needed per state.

**Measured 2026-09-14 — real playtest capture, `LANDING_MOMENTUM_GRACE_SECONDS`
sized from it.** With `SPEED_SANITY_DEBUG_LOGGING` on, repeatedly sprinting,
jumping, and landing while still holding forward produced four clean
`Airborne -> Walk` samples (cap 40.0 -> 18.0 each time):

| landing -> first check | elapsed | flatDelta | maxDistance (new cap) | 2nd correction? |
|---|---|---|---|---|
| +0.500s | 0.500 | 12.64 | 11.70 | none |
| +0.517s | 0.517 | 13.09 | 12.09 | none |
| +0.515s | 0.515 | 13.13 | 12.04 | none |
| +0.501s | 0.501 | 12.61 | 11.73 | none |

Two things this data settled: (1) the first `enforceSpeedSanity` check after a
landing always fires at elapsed ≈0.50-0.517s — just the normal
`SpeedCheckIntervalSeconds` cadence — and every printed `maxDistance` in that
first check matched `WalkSpeed * elapsed * SpeedToleranceMultiplier` exactly,
which means the original placeholder grace (one `SpeedCheckIntervalSeconds`,
0.5s) had **already expired by the time that first check ran** (`elapsed >=
grace` the instant the check fires) — it was measuring zero actual protection,
not a slightly-too-short one. (2) None of the four landings produced a second
correction after the first snap-back — the whole residual-momentum transient
is contained inside that one first window; by the second window (~1.0s post-
landing) real velocity is already back under the new cap on its own, with no
evidence a longer grace was ever needed.

`LANDING_MOMENTUM_GRACE_SECONDS` set to `2 * SpeedCheckIntervalSeconds` (1.0s)
accordingly — comfortably covers the observed ~0.5-0.517s first check with
margin, without over-granting a second window's worth of grace the capture
never showed a need for. `SPEED_SANITY_DEBUG_LOGGING` flipped back to `false`
per this file's own established pattern.

**Noted, not fixed, out of scope for this pass** — the same capture also
showed two `state=Run` corrections (flatDelta 19.52/18.34 vs. a `RunSpeed`-cap
maxDistance of 18.82/18.20) with no preceding "grace window started" print,
several seconds after the nearest landing — too late to be that landing's own
residual momentum, and no cap-decreasing transition logged immediately before
either one. This doesn't match either bug fixed today; it looks like the
already-documented "§5 residual gap" above (a modified-or-unlocked-camera
client holding Sprint-tier speed while mirrored as Run, via the `AutoRotate`
gate on the server-side backpedal demotion) rather than a new issue. Left
as-is and cross-referenced here rather than silently ignored — revisit if it
turns out to reproduce reliably rather than being that already-accepted gap.

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
   `AutoRotate` off) and `LocomotionAnimator` (Walk's 8-directional bucket
   selection + crossfade; Idle/Run/Sprint each a single non-directional clip,
   reading real Animation instances) are both built per §4. No Airborne clip yet,
   and blending is a discrete crossfade, not a true blend space — see §4 for why.
   `Assets/Animations/Movement.model.json` ships with every `AnimationId` blank;
   fill in real Walk/Run/Sprint/Idle IDs from Studio's property panel once those
   animations are uploaded — no code change needed to pick them up.
4. **Exploit + perf pass** — ✅ done 2026-09-13. Server-side speed/delta-position
   sanity check built (`MovementValidationService.enforceSpeedSanity`, previously
   never implemented despite §5 describing it); Sprint-timestamp legality check
   audited and one real gap fixed (`runEnteredAt` wasn't reset on server-side
   Sprint→Run demotion, letting a client that skipped the "Run" reclaim instantly
   re-earn Sprint off a stale timestamp); rate-limit gap already resolved in Step 2
   (`RateLimiter`, wired in `MovementValidationService`), reconfirmed still wired
   correctly; `Trove` audit — every stateful client/server object
   (`FacingController`, `LocomotionAnimator`, `CharacterMover`, `InputController`,
   `StateMachine`, both FSM instances) owns exactly one, torn down at the right
   boundary, nothing leaked; `os.clock()` audit — zero `tick()` usages anywhere in
   `src/`.

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

## 8. Debug Tooling

**Added 2026-09-13, rebuilt 2026-09-14 — F4 developer debug overlay.** Per
`docs/ARCHITECTURE.md` §8, the panel itself is a hand-authored, checked-in Rojo
instance tree — `Assets/UI/MovementDebugOverlay.model.json`, mounted at
`StarterGui.MovementDebugOverlay` — same `$className`/`Properties`/`Children`
approach as `Assets/Animations/Movement.model.json`, verified against the real
`rojo build` before any consuming code was written. `Client/Controllers/DebugOverlayController.luau`
only ever `WaitForChild`s into it and sets `.Text`/`.Visible`/`.TextColor3` on
existing instances — it never constructs a single UI element.

- **Client state**: read from `Client/Controllers/Movement/DebugSnapshot.luau`, a
  small published-state module `Movement/init.luau` writes to every Heartbeat
  (state name, grounded, `Run` duration, flattened `AssemblyLinearVelocity`
  magnitude) — `DebugOverlayController` polls it rather than reaching into
  `MovementController` directly (`docs/ARCHITECTURE.md` §2).
- **Server state**: `MovementValidationService.broadcastDebugState` fires a new
  `MovementDebugState` event (`network.zap`, `Server -> Client`, `Unreliable`,
  restricted to the owning player and only ever sent to developers at all) every
  Heartbeat with the session's mirrored `fsm.current`, `Run` duration, and current
  `ViolationTracker` count. The panel visually flags client/server disagreement —
  the whole point of the panel, given this doc's own rubber-banding investigation
  above — by recoloring the server state value and showing a dedicated mismatch
  label whenever the two differ.
- **Teleport tool**: coordinate entry or click-a-point-in-workspace (a
  `Workspace:Raycast` from the mouse), firing `RequestDevTeleport` (`network.zap`,
  `Client -> Server`) like any other remote — never a raw `RemoteEvent`. Authorized
  by `Shared/Constants/DeveloperAllowlist.luau` (`RunService:IsStudio()` or a
  hardcoded `UserId` allowlist), checked **first** in `DevToolsService`'s handler,
  before anything else runs — client-side overlay visibility uses the exact same
  check, but is never the actual security boundary. Also rate-limited via the
  shared `RateLimiter`, same as every other player-initiated remote (§5).
  Teleporting bypasses normal Humanoid movement entirely, so
  `MovementValidationService.enforceSpeedSanity` would otherwise measure it as an
  impossible jump and snap the player straight back on the next sample — fixed by
  a new `Server/Events/CharacterTeleported.luau` signal `DevToolsService` fires
  after a successful teleport, which `MovementValidationService` subscribes to in
  order to reset its speed-check baseline (the same "reset the baseline, don't pad
  the tolerance" approach this doc's §5 rubber-banding fix used). This is a
  server-to-server pub/sub channel, not either service reaching into the other's
  session state directly (`docs/ARCHITECTURE.md` §2).
- **Combat/M1**: `CombatSection` in the instance tree is a deliberately empty,
  clearly labeled placeholder — nothing to wire up until that system exists.

**Bug found 2026-09-13, real cause found 2026-09-14 — the panel went blank a
moment after opening.** A long investigation with several wrong turns, kept here
in full because each wrong turn is a real trap worth not falling into twice:

1. First suspected `CanvasGroup` (used for a `GroupTransparency` fade in/out): it
   composites its entire subtree into a single cached texture, and seemed not to
   re-render that texture against this panel's own Heartbeat-driven
   `TextLabel.Text` updates. Switched `Panel` to a plain `Frame` with a
   `Position` slide instead — the exact same "flashes correct, then blank"
   symptom reproduced identically.
2. Suspected the F4 handler was double-toggling on OS key-repeat (no debounce
   against the key itself — only against `isOpen`). Added `f4Held`
   tracking. Real playtest logs (`setOpen`/`playFade`/`InputBegan`/`InputEnded`
   all instrumented with prints) proved this theory *wrong*: a single F4 press
   produced exactly one `InputBegan`, one `setOpen(true)`, one `playFade(true)`,
   and no close call at all — yet the panel still went blank. Three unrelated
   animation techniques (`CanvasGroup` fade, `Position` slide, per-element
   `TextTransparency`/`BackgroundTransparency` tweening) and a debounce fix all
   producing the identical symptom was the actual tell that neither the
   animation nor the toggle logic was ever the bug.
3. **The real cause: `Panel` had `ZIndex = 10` (so it would draw above its
   sibling `CornerTab`), while every descendant inside it was left at the
   default `ZIndex = 1`.** Live property inspection during a blank episode
   confirmed every single property on the affected `TextLabel`s was correct —
   `TextTransparency = 0`, correct `TextColor3`, correct `Text`, `Visible =
   true` — proving the bug was never in this controller's logic at all, only in
   rendering order. With a `ZIndexBehavior` that resolves a parent's own
   background against the whole tree rather than strictly against its own
   children, a parent's higher `ZIndex` than its descendants can make that
   parent's opaque background paint *over* its own children. That's exactly
   why every fix "flashed correct, then went blank" regardless of technique:
   during the fade-in, `Panel`'s own background was still transparent (nothing
   to obscure), and the moment it finished tweening to fully opaque, it drew
   over everything inside it. Confirmed by manually forcing
   `Panel.BackgroundTransparency = 1` live in Studio — the "hidden" panel
   background stopped painting over its children, and all text reappeared.

Fixed by setting `ZIndex = 0` on both `CornerTab` and `Panel` — explicitly below
every descendant's default `ZIndex = 1`, guaranteeing children always draw on top
regardless of `ZIndexBehavior` mode — rather than pushing every descendant's
`ZIndex` above the container instead. The two containers are never visible at the
same time (this controller always hides one when showing
the other), so neither ever needed to out-rank the other in the first place.
Kept the per-element fade from step 1's third attempt (asked for back on its own
merits — "it was clean") and the `f4Held` debounce from step 2 (harmless, and
real insurance against a genuine double-press) since both are strictly
correct/more-robust code regardless of not having been the actual bug, plus
per-target `pcall` isolation around the fade's property writes and
`TweenService:Create` calls so one bad target can never silently take out every
target after it in the loop again.

**Extended 2026-09-14 — Movement/World/Tuning tabs, live tuning, noclip,
waypoints, and richer history.** The flat panel above grew enough new
functionality (below) that it needed real navigation —
`Assets/UI/MovementDebugOverlay.model.json`'s `Panel` is now three collapsible
tabs (`TabBar` + `TabContent.{MovementTab,WorldTab,TuningTab}`,
`DebugOverlayController.setTab`) instead of one long scroll, and is draggable by
its `TitleRow` (standard Roblox drag-by-titlebar: `InputBegan` on the title bar
captures the press-start mouse position and the panel's own `Position`, a global
`UserInputService.InputChanged` applies the accumulated delta every frame) —
position is remembered for the session for free, since nothing resets
`panel.Position` on close/reopen. `CombatSection` and its preceding `Divider3`
are unchanged and untouched, and sit outside the tab system entirely (combat
doesn't exist yet). The per-element transparency-tween fade (see the blank-panel
writeup above) is unchanged — `collectFadeTargets` already walks every
descendant regardless of which tab happens to be visible.

- **Centralized dev-only gate.** Every dev-only remote now routes through one
  wrapper, `DevToolsService.RegisterDevOnly(handler)`, instead of a copy-pasted
  `DeveloperAllowlist.IsDeveloper` check at the top of each handler — extracted
  *before* any remote past `RequestDevTeleport` existed, specifically so the
  check can never be forgotten on remote N. `RequestDevTeleport`'s own handler
  was migrated onto it first, as the proof it behaves identically; the noclip and
  tuning remotes below were both built directly on it, never with their own
  inline check.
- **Movement tab — state history.** `Client/Controllers/Movement/DebugSnapshot.luau`
  keeps a bounded ring buffer (`STATE_HISTORY_LIMIT = 10`) of the client FSM's
  `fsm.changed` transitions with timestamps (`RecordTransition`/`GetStateHistory`),
  populated by `Movement/init.luau` off its existing `fsm.changed` connection —
  no new connection needed. Rendered under `ClientSection` as a small scrolling
  list (`StateHistorySection`), most-recent-first, in a fixed 10-row pool
  (`Row1..Row10`) the controller shows/hides rather than constructing at runtime.
- **Movement tab — full velocity readout.** `DebugSnapshot`'s published snapshot
  now carries the root part's real `AssemblyLinearVelocity`/`AssemblyAngularVelocity`
  (`velocity`/`rotVelocity`) alongside the flattened horizontal `speed` it already
  had (kept, not replaced — still the quickest single number to eyeball against a
  state's speed tier). Two new rows under `ClientSection`.
- **Movement tab — network claim log.** `DebugSnapshot.RecordClaim`/`GetClaimLog`
  log the client's own `RequestMovementTransition` sends (Run/Sprint claims) in a
  bounded ring buffer (`CLAIM_LOG_LIMIT = 8`), called from the same call site
  `Movement/init.luau` already fires the claim from (`fireClaim`, shared by the
  `fsm.changed` edge and the periodic resync). Deliberately no new ack/response
  remote — `DebugOverlayController.reconcileClaimLog` infers accepted-vs-likely-
  rejected by checking whether the existing `MovementDebugState` broadcast ever
  reflects the claimed state within `CLAIM_REFLECT_TIMEOUT_SECONDS` (2s) of the
  claim, mutating `ClaimLogEntry.reflected` on the shared history in place (`nil`
  = pending, `true` = confirmed, `false` = timed out unconfirmed). Rendered under
  a new `ClaimLogSection`, most-recent-first, flagging any entry still `false`.
- **Movement tab — violation history.** `Shared/Util/ViolationTracker.luau`'s
  `Violation` record now keeps a bounded `history` of individual recent entries
  (`HISTORY_LIMIT = 5`), not just the running `count`/`lastAt` —
  `MovementValidationService.enforceSpeedSanity` pushes the exact same
  `flatDelta`/`maxDistance`/`elapsed` numbers `SPEED_SANITY_DEBUG_LOGGING` already
  printed into that history instead of only ever printing them. `MovementDebugState`
  (`network.zap`) now carries a bounded `violations` array alongside
  `violationCount`, with `ageSeconds` computed fresh server-side on every
  broadcast (`os.clock() - recordedAt`) since the two machines' clocks aren't
  comparable. Rendered under a new `ViolationHistorySection` beneath
  `ServerSection`.
- **Tuning tab — live-tunable movement constants.** `Shared/Movement/MovementTuning.luau`
  defines the live-tunable subset of `MovementConstants` (`RunDoubleTapWindowSeconds`/
  `SprintThresholdSeconds`/`WalkSpeed`/`RunSpeed`/`SprintSpeed`/`JumpPower`/
  `SprintForwardDeadzone`/`SpeedToleranceMultiplier`) plus per-name sanity bounds
  (`IsValidValue`) and a defaults/override-merge helper (`Defaults`/`WithOverrides`).
  `Server/State/MovementTuningState.luau` holds a per-player override table
  (never global — there is no key that means "everyone");
  `Server/Services/MovementTuningService.luau` is the dev-gated `RequestSetTuning`
  handler (bounds-checked, `value == nil` clears) and broadcasts the session's
  effective constants back down over `TuningState`. `StateRules.CanEnter`,
  `MovementValidationService.buildContext`, and every client state module now
  read `context.constants`/`TuningSnapshot.Get()` — this session's effective
  values — instead of importing `MovementConstants` directly, so a live override
  changes client feel and server enforcement identically and can never drift into
  the exact false-positive rubber-banding class this doc's §5 investigation
  already had to fix once. Overrides apply only to the tuning developer's own
  session, take effect with no republish, and reset on `PlayerRemoving`. The
  overlay's Tuning tab renders one row per name (current effective value, an
  input box, Set/Clear buttons) and never computes or validates a value itself —
  it only ever sends a claim, same trust model as every other dev-only remote.
- **World tab — noclip/fly.** `RequestSetNoclip` (dev-gated) toggles
  `Server/State/NoclipState.luau`, a per-player server-authorized record — never
  a client-reported flag — that `MovementValidationService.enforceSpeedSanity`
  exempts entirely while active (otherwise it would immediately rubber-band the
  very tool that exists to move faster than any tier's cap). `DevToolsService`
  also disables `CanCollide` on every character `BasePart` server-side (replicates
  natively); the actual fly movement is driven client-side by
  `Client/Controllers/Movement/NoclipController.luau` (Space/Ctrl for up/down,
  `Humanoid.PlatformStand = true` while active so Roblox's own ground controller
  doesn't fight the per-frame `CFrame` writes), since the player's own character
  is already network-owned by that client for ordinary movement. Turning noclip
  off re-fires `CharacterTeleported` (the same signal the dev-teleport tool
  already uses) so `enforceSpeedSanity`'s baseline doesn't compare the
  discontinuous re-entry position against wherever the player was flying. The
  overlay's toggle button always requests the opposite of the last
  SERVER-CONFIRMED state (`DebugSnapshot.Get().noclip`, itself fed from the
  `NoclipState` broadcast), never a locally-guessed "what did I just click" flag.
- **World tab — named waypoints.** Session-only, client-side, deliberately not
  `ProfileStore`-backed — same "no reason to touch persistence for this"
  reasoning as the panel's dragged position above. A plain local `name -> Vector3`
  list inside `DebugOverlayController` (capped at 8, matching the fixed row pool
  in `WaypointsSection.List`), with save-here and per-row jump/delete. Jumping
  reuses `RequestDevTeleport` — no new teleport remote.

None of the above touch `CombatSection` — still a deliberately empty, clearly
labeled placeholder, unchanged from when §8 first shipped it.

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
- **`enforceSpeedSanity` has no carve-out for externally-applied velocity.**
  Flagged 2026-09-13 during the Step 4 rubber-banding fix: the speed/delta-position
  check (`MovementValidationService.luau`, docs/MOVEMENT.md §5) assumes all
  horizontal motion comes from the player's own `WalkSpeed` tier. Inert today —
  nothing in Phase 1 produces extra velocity — but knockback, launch pads, and
  combat's future `Overridden`/Dash state all will, and none of them will replicate
  as a legible state change this check already knows to reset its baseline on
  (unlike a Sprint/Run/Walk transition, an external shove doesn't fire
  `fsm.changed`). Whichever system adds the first of these needs to give this
  check an explicit exemption window (the same "reset the baseline, don't guess a
  bigger tolerance" approach used above) — not something to work out now, just
  flagged so Stage 2/combat work doesn't get silently rubber-banded by this later.

Ask for the full spec on any of these when you're ready to build them.
