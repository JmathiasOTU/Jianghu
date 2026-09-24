# Architecture

This document is the standing set of design rules for Jianghu. It applies to every system in this repository — movement, combat, UI wiring, and persistence alike. Pull requests that violate these rules should be rejected in review regardless of whether the feature "works."

Sections 1–14 are the rules; code comments cite them as `ARCHITECTURE §N`, so their numbers don't change. §15 covers the stack, layout and workflow. How the movement system itself works is in [`MovementSystem.md`](MovementSystem.md).

## 1. Project Identity

- **Rig standard:** R6 only, exclusively, to guarantee identical hitbox fairness across all players. No code should branch on or accommodate R15 or custom rigs.
- **Combat identity:** Jianghu is a parry-based combat game. Parry timing, stagger/posture, and server-authoritative hit validation are first-class systems — never bolted onto a generic combat script as an afterthought.

## 2. Global Rules

- **Single entry point.** The client boots exclusively through `ClientBootstrap.luau`; the server boots exclusively through `ServiceBootstrap.luau`. Both use `Loader.LoadChildren` to require every module in their respective `Controllers`/`Services` folder and `Loader.SpawnAll(modules, "Init")` to start them — no manual require loops, and no stray `LocalScript`/`Script` instances placed ad hoc in the Explorer. Every controller/service module returns a table exposing an `Init` function as its lifecycle entry point.
- **Finite state machines everywhere.** Every stateful system (combat, movement, interactions) is governed by an explicit, decoupled FSM built on `LemonSignal`. FSM states are `Symbol` values (`Shared/FSM`), never raw strings — a typo in a string state name fails silently, a typo in a `Symbol` reference fails to compile/require.
- **Strict pub/sub decoupling.** Controllers never reach into each other directly. They subscribe to shared state modules and react to events.
- **Data-driven, zero magic numbers.** No numeric literal (impulse vectors, durations, speeds, cooldowns) lives inline in functional code. Everything routes through centralized constants modules (`MovementConstants.luau`, `CombatConstants.luau`, etc.).

## 3. Security Model — "The Client Is a Liar"

Roblox networking defaults to trusting the client. This codebase overrides that assumption everywhere it matters.

- **Client predicts, server decides.** The client renders movement/animation/effects immediately for responsiveness, but every meaningful state transition is validated server-side before it's treated as real.
- **Server-side FSM mirroring.** Server validation services maintain their own lightweight copy of each player's FSM state and reject any transition the mirror says is illegal.
- **Server-owned cooldowns.** Cooldown timers live in server-side player state, never in client closures.
- **Sanity raycasts.** Any spatial claim (wall-run, vault, climb, etc.) is checked against real geometry near the character's server position before it's accepted.

## 4. Parry Combat

Parry is the most exploited and most defining system in this genre, and is held to its own contract:

- Parry windows are explicit constants in `CombatConstants.luau`. No controller computes or hardcodes its own window.
- Parry legality is validated against the **attacker's** timestamp via lag compensation — never against the defender's local clock, which would punish high-ping players and hand low-ping players a free auto-parry.
- Combat runs a posture/stagger meter alongside HP, as its own explicit FSM state, mirrored server-side.
- Feinting (if present) is its own explicit FSM state, distinct from an exploited animation cancel.
- Hitstop/hitlag values are data-driven per attack type — never a hardcoded `wait()`/`task.wait()`.
- Back-attacks and blindsides are validated with facing-angle checks, not just geometry existence.

## 5. Anti-Exploit

- Statistically inhuman parry consistency is tracked and flagged independently of normal state validation.
- Parry (and all combat/movement) events are rate-limited at the remote layer, separate from any FSM cooldown, to stop macro/script spam — enforced via the shared `RateLimiter` utility (`Shared/Util/RateLimiter.luau`) applied at the top of each remote handler, never a bespoke debounce duplicated per handler. Zap's `.zap` config has no native per-event rate-limit field, so this cannot be declared on the event itself — it's enforced in code, deliberately centralized in one utility instead of ad hoc per handler.

## 6. Performance & Memory

- `os.clock()` only — never `tick()`.
- Dense raycasts are throttled via delta-time accumulators, not run raw on every `RenderStepped`.
- Every stateful object (FSMs, per-character controllers, per-session server state) owns a `Trove` instance. Connections, spawned threads, and promises are added to it via `Trove:Add`/`Trove:Connect`/`Trove:AddPromise` as they're created, never tracked by hand.
- On death/respawn/cleanup, that object's `Trove:Destroy()` is called once — this disconnects every listener and cancels every pending thread/promise it owns in one call, which is what prevents the memory leaks and GC pressure this rule exists to avoid. A new `Trove` is created for the next life/session; troves are never reused across a cleanup boundary.

## 7. Style

- Strict Luau typing (`--!strict`) wherever applicable.
- `PascalCase` for classes/services/controllers/enums, `camelCase` for locals/functions/constants, `_prefix` for private table members.
- OOP-style methods on a class/object instance (e.g. `Trove:Add`, `fsm:RequestTransition`) are `PascalCase`, matching `Trove`/`LemonSignal`/`Loader` and every native Roblox `Instance` method — not the `camelCase` used for plain functions/locals. A file mixing `self._trove:Add(...)` and `self:destroy()` a few lines apart is a style bug to fix, not a judgment call to make per-file.
- Tabs for indentation, 100-column soft limit, no semicolons.
- `ipairs` for arrays, `pairs` for dictionaries — never mixed keys in one table.
- Never yield the main thread; use `task.spawn`/`task.defer`/promises, and `pcall` or `success, result` returns for fallible calls.
- Code is self-documenting. Comments are reserved for genuinely non-obvious math, engine quirks, or workarounds — one line, no restating what the code already says.

## 8. GUI & Persistence

- GUIs are hand-built in Studio. Scripts only `WaitForChild` into existing instances — never construct `ScreenGui`s or UI elements from code.
- Player data is session-locked on join; all critical data operations are atomic and fail-safe.

## 9. No Band-Aid Validation

Server-side tolerances are never padded arbitrarily to paper over latency or desync — that's a root-cause failure to fix, not a number to nudge. A tolerance is only acceptable when it corresponds to a specific, measured, documented engine behavior (e.g. a known transient in Humanoid's ground controller after a dash-cancel). If you can't point to the measured cause, the tolerance doesn't belong in the codebase.

## 10. Remote Communication

- **All remotes are declared in [`network.zap`](../network.zap) and consumed only through the generated `src/Client/Network/network.luau` / `src/Server/Network/network.luau` modules.** No raw `RemoteEvent` instances are created or fired by hand — Zap's generated API is the only interface to networking in this codebase, and it type-validates every argument by construction. `network.zap` is regenerated with `zap network.zap` any time it changes; the generated files are build artifacts and are not committed.
- Fire-and-forget events only — never a synchronous request/response pattern (`RemoteFunction`, or a server-side `yield`/`Wait` on a client's reply), which can hang the server thread on a non-responding client.
- Every player-initiated combat/movement remote is gated by the shared `RateLimiter` utility (`Shared/Util/RateLimiter.luau`) in its handler, independent of its game-logic cooldown. `network.zap` has no field for this — see §5.

## 11. Physics & Network Ownership

Any part whose position the server treats as ground truth (hitbox proxies, projectiles, etc.) is either `Anchored` and moved by script, or has its network ownership explicitly pinned to the server (`SetNetworkOwner(nil)`) — never left to Roblox's automatic client assignment.

## 12. Player State

- HP, posture, and Qi are custom profile values, never `Humanoid.Health`, which is held at a fixed value purely as a rig-compatibility shell.
- `Humanoid.Died` is not the defeat trigger. The custom HP-reaches-zero check drives the `Defeated` FSM state directly; an unrelated `Died` firing (kill volume, script error) must not be treated as a combat defeat.

## 13. Data Persistence

- **All player data goes through `ProfileStore` (`ServerPackages/ProfileStore`).** It is the only sanctioned interface to `DataStoreService` in this codebase — no service calls `GetAsync`/`SetAsync`/`UpdateAsync` directly. ProfileStore already provides `UpdateAsync`-based writes, session locking, retry-with-backoff, and a `BindToClose` final save; a hand-rolled DataStore call anywhere else in the codebase is a rule violation, not a stylistic choice.
- Profile schema defaults are reconciled with `TableUtil.Reconcile`, never a manual key-by-key migration, so old profiles pick up new fields without a bespoke script per schema change.

## 14. World Streaming

`StreamingEnabled` is a deliberate, documented decision for this project — not a default left unconsidered. Server-side hit detection is unaffected by it either way; the risk is client-side prediction/animation desync for characters that haven't streamed in yet. If enabled, the minimum streaming radius relative to combat engagement range is documented here as the project settles on it.

**Decision (2026-09-24): enabled.** The setting lives on `Workspace` in the place file, not in `default.project.json`. **TODO:** confirm it in Studio and record `StreamingMinRadius`/`StreamingTargetRadius` here once combat engagement range is known.

Consequences for movement (audit M-034):
- **Server validation is unaffected.** The server always has the full world, so its own ground, wall, climbable and water probes are never missing geometry.
- **Client prediction only errs on the safe side.** A wall or floor that hasn't streamed in yet can't be found by the client's `QueryWallRun`/`QueryClingWall`/`QueryGround`, so the client under-predicts (no wall run or cling there yet). It never claims something the server will reject. Traversal level geometry should sit inside the streaming radius of wherever players approach it from.
- **Never make a gameplay decision client-side from the absence of a part.** "I don't see a wall, so there isn't one" is only a prediction.

## 15. Stack, Layout and Workflow

Jianghu is a Roblox parry-combat/movement RPG. Read this file and [`CONTRIBUTING.md`](../CONTRIBUTING.md) in full before making changes.

**Stack:** Rojo + Luau (`--!strict`) + Wally. Signals: LemonSignal. Cleanup: Trove. Networking: Zap (`network.zap` → generated `network.luau`). Persistence: ProfileStore. Lint/format: Selene + StyLua. Tests: Lune. R6 only. Tool versions are pinned in `aftman.toml`.

**Layout:**
- `src/Client/Controllers/` — client controllers. `Movement/` is the FSM-driven movement system: one file per state under `States/`, with `init.luau` as the per-life orchestrator.
- `src/Server/Services/` — server services. `MovementValidationService.luau` mirrors each player's movement FSM independently and never trusts a client-claimed state or value.
- `src/Server/State/`, `src/Server/Events/` — per-player server records; server-to-server signals.
- `src/Shared/` — Constants, FSM primitives, types, and pure movement math/geometry (`StateRules`, `TraversalMath`, `SpatialQueries`), called identically by client and server.
- `Assets/` — Studio-authored instance trees (animations, UI) synced by Rojo.
- `tests/` — Lune specs for the pure shared modules.
- `docs/` — this file and `MovementSystem.md`.

**Before starting a task:** skim `src/Shared/Types/MovementTypes.luau` (the shared context shape) and the relevant state files. Existing comments often record *why* a decision was made and whether a constant is still unmeasured; read them before "fixing" something flagged as intentional. How that fits §7's one-line comment rule is an open question (see `MovementSystem.md` §14).

**Before pushing** (CI runs the same checks):

```bash
zap network.zap                    # after any network.zap change
selene src
stylua --check src tests --glob '!src/**/Network/network.luau'
lune run tests/run
rojo build default.project.json --output build.rbxl
```
