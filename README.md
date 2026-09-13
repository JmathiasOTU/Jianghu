# Murim Ascent

A fast-paced, parry-based movement RPG built for Roblox.

Murim Ascent is a combat-first experience in the vein of *Deepwoken*, *Nethros*, and *Type Soul* — built around tight parry timing, momentum-driven movement, and server-authoritative combat resolution. This repository contains the full Rojo-managed source for the game.

## Status

This repository is undergoing a full architectural rework: movement, combat, and core systems are being rebuilt from the ground up on a strict FSM + data-driven foundation. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the standing design rules this codebase is held to.

## Tech Stack

| Layer | Tooling |
|---|---|
| Sync / Build | [Rojo](https://rojo.space/) |
| Language | Luau (strict mode) |
| Package Management | [Wally](https://wally.run/) |
| Signals | [LemonSignal](https://github.com/Data-Oriented-House/LemonSignal) |
| Bootstrapping | [Loader](https://sleitnick.github.io/RbxUtil/api/Loader) (single-entry-point service/controller loading) |
| Lifecycle Cleanup | [Trove](https://sleitnick.github.io/RbxUtil/api/Trove) (connections, threads, promises) |
| Async | [Promise](https://eryn.io/roblox-lua-promise/) |
| Table Utilities | [TableUtil](https://sleitnick.github.io/RbxUtil/api/TableUtil) |
| Linting | [Selene](https://kampfkarren.github.io/selene/) |
| Formatting | [StyLua](https://github.com/JohnnyMorganz/StyLua) |
| Rig Standard | R6 |

## Project Structure

```
src/
├── Client/
│   ├── ClientBootstrap.client.luau   # Single client entry point
│   ├── Controllers/                  # FSM-driven client controllers
│   └── UI/                           # UI wiring (WaitForChild only — no GUI construction in code)
├── Server/
│   ├── ServiceBootstrap.server.luau  # Single server entry point
│   └── Services/                     # Server-authoritative validation & game logic
└── Shared/
    ├── Constants/                    # Centralized, data-driven tuning (zero magic numbers)
    ├── FSM/                          # Shared finite state machine primitives
    ├── Types/                        # Shared Luau type definitions
    └── Util/                         # Stateless shared utilities
```

## Getting Started

### Prerequisites

- [Rojo](https://rojo.space/docs/installation/) `>= 7.4`
- [Wally](https://github.com/UpliftGames/wally) `>= 0.3`
- [Aftman](https://github.com/LPGhatguy/aftman) (recommended, for toolchain management)

### Setup

```bash
# Install pinned CLI tooling (Rojo, Wally, Selene, StyLua)
aftman install

# Install Luau dependencies
wally install

# Serve the project to Roblox Studio
rojo serve
```

Connect to the running Rojo server from the Rojo Studio plugin to sync `src/` into Studio.

### Linting & Formatting

```bash
selene src
stylua --check src
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for code style, architecture constraints, and the pull request process. All changes are expected to conform to the rules in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — this is enforced in review, not optional guidance.

## License

All rights reserved. See [`LICENSE`](LICENSE) for details.
