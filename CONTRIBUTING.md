# Contributing

Thanks for helping build Murim Ascent. This project holds a high, consistent bar for architecture because it's a parry-timing combat game — small inconsistencies in how state and networking are handled translate directly into exploitable or unfair gameplay.

Before opening a PR, read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) in full. It is not optional background reading — it's the checklist your change will be reviewed against.

## Workflow

1. Branch off `main` using `type/short-description` (e.g. `feat/wall-run-fsm`, `fix/parry-window-desync`).
2. Keep PRs scoped to a single system or fix. Large multi-system PRs are hard to review against the architecture rules and will likely be asked to split.
3. Run linting and formatting locally before pushing:
   ```bash
   selene src
   stylua --check src
   ```
4. Open a PR against `main` using the provided template. Fill in every section — reviewers will bounce PRs that skip the architecture checklist.

## Non-negotiables

These are enforced in review without exception:

- No hardcoded numeric tuning values in functional scripts — route through `Shared/Constants`.
- No client-authoritative combat/movement outcome. The server must validate every state transition.
- No `RemoteFunction` usage for combat or movement.
- No GUI construction from code — UI scripts only `WaitForChild` into Studio-built instances.
- No `tick()` — use `os.clock()`.
- No stray `LocalScript`/`Script` instances outside the bootstrap-driven module tree.

## Commit messages

Write commit messages that explain *why*, not just *what*. `Fix parry window` is not useful; `Validate parry against attacker timestamp to fix high-ping false rejections` is.

## Questions

If a design decision isn't covered by `docs/ARCHITECTURE.md`, raise it in the PR description rather than guessing — architecture consistency matters more than shipping speed here.
