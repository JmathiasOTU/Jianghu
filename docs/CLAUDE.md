# Jianghu — CLAUDE.md

Roblox parry-combat/movement RPG, currently mid-rework on the movement system.
Read `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` in full before making changes —
they're the enforced rulebook, not suggestions.

## Stack
Rojo + Luau (strict) + Wally. Signals: LemonSignal. Cleanup: Trove. Networking:
Zap (`network.zap` → generated `network.luau`, never hand-written RemoteEvents).
Persistence: ProfileStore only. Lint/format: Selene + StyLua (`selene.toml`/`stylua.toml`).
R6 only.

## Layout
- `src/Client/Controllers/Movement/` — FSM-driven client controllers, one file per
  state under `States/`. `init.luau` is the per-life orchestrator.
- `src/Server/Services/MovementValidationService.luau` — server mirrors the client's
  FSM independently and never trusts a client-claimed state/value.
- `src/Shared/` — Constants, FSM primitives, pure movement math (`TraversalMath`,
  `SpatialQueries`, `StateRules`), all called identically by client and server.

## Non-negotiables (see ARCHITECTURE.md for full list)
- Single entry point via `Loader.LoadChildren` + `SpawnAll(_, "Init")`.
- FSM states are `Symbol` values, never raw strings.
- Zero magic numbers — tunables go in `Shared/Constants/MovementConstants.luau`.
- Server validates every state transition against its own mirrored state/geometry —
  "the client is a liar."
- No GUI built from code — UI scripts only `WaitForChild` into Studio-built instances.
- `os.clock()`, never `tick()`. Every stateful object owns a `Trove`.
- PascalCase for OOP methods (`self:Foo()`), camelCase for locals/functions.

## Before starting any task
Skim `src/Shared/Types/MovementTypes.luau` (the shared context shape) and whichever
state files are relevant. Comments in this codebase are unusually thorough and
often say *why* a decision was made and whether a constant is still unmeasured —
read them before "fixing" something that's actually already flagged as intentional.