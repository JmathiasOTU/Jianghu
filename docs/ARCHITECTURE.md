# Architecture

This document is the standing set of design rules for Murim Ascent. It applies to every system in this repository — movement, combat, UI wiring, and persistence alike. Pull requests that violate these rules should be rejected in review regardless of whether the feature "works."

## 1. Project Identity

- **Rig standard:** R6 only, exclusively, to guarantee identical hitbox fairness across all players. No code should branch on or accommodate R15 or custom rigs.
- **Combat identity:** Murim Ascent is a parry-based combat game. Parry timing, stagger/posture, and server-authoritative hit validation are first-class systems — never bolted onto a generic combat script as an afterthought.

## 2. Global Rules

- **Single entry point.** The client boots exclusively through `ClientBootstrap.luau`; the server boots exclusively through `ServiceBootstrap.luau`. No stray `LocalScript`/`Script` instances placed ad hoc in the Explorer.
- **Finite state machines everywhere.** Every stateful system (combat, movement, interactions) is governed by an explicit, decoupled FSM built on `LemonSignal`.
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
- Parry (and all combat/movement) `RemoteEvent`s are rate-limited at the remote layer, separate from any FSM cooldown, to stop macro/script spam.

## 6. Performance & Memory

- `os.clock()` only — never `tick()`.
- Dense raycasts are throttled via delta-time accumulators, not run raw on every `RenderStepped`.
- All event connections are explicitly `:Disconnect()`ed on death/respawn/cleanup.
- Active `task.delay` threads are tracked in a registry and `task.cancel()`ed when superseded, to avoid GC pressure under input spam.

## 7. Style

- Strict Luau typing (`--!strict`) wherever applicable.
- `PascalCase` for classes/services/controllers/enums, `camelCase` for locals/functions/constants, `_prefix` for private table members.
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

- Every remote handler type-validates every argument before it touches game logic.
- `RemoteEvent`s only — never `RemoteFunction`s, which can hang the server thread on a non-responding client.
- Every player-initiated combat/movement remote is rate-limited independently of its game-logic cooldown.

## 11. Physics & Network Ownership

Any part whose position the server treats as ground truth (hitbox proxies, projectiles, etc.) is either `Anchored` and moved by script, or has its network ownership explicitly pinned to the server (`SetNetworkOwner(nil)`) — never left to Roblox's automatic client assignment.

## 12. Player State

- HP, posture, and Qi are custom profile values, never `Humanoid.Health`, which is held at a fixed value purely as a rig-compatibility shell.
- `Humanoid.Died` is not the defeat trigger. The custom HP-reaches-zero check drives the `Defeated` FSM state directly; an unrelated `Died` firing (kill volume, script error) must not be treated as a combat defeat.

## 13. Data Persistence

- `UpdateAsync` only — never a `GetAsync`/`SetAsync` pair, which races across concurrent sessions.
- DataStore writes retry with exponential backoff and a capped attempt count.
- `game:BindToClose()` attempts a final save with a bounded timeout before shutdown.

## 14. World Streaming

`StreamingEnabled` is a deliberate, documented decision for this project — not a default left unconsidered. Server-side hit detection is unaffected by it either way; the risk is client-side prediction/animation desync for characters that haven't streamed in yet. If enabled, the minimum streaming radius relative to combat engagement range is documented here as the project settles on it.
