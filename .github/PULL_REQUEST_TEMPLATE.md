## Summary

<!-- What does this change do, and why? -->

## System(s) touched

<!-- e.g. Movement FSM, Parry validation, Stagger/posture, Persistence -->

## Architecture checklist

- [ ] No hardcoded tuning values — all numeric constants live in `Shared/Constants`
- [ ] Every new stateful system is modeled as an explicit FSM
- [ ] Server validates/mirrors any new client-claimed state (no trust-the-client gaps)
- [ ] No new `RemoteFunction` usage (`RemoteEvent` only)
- [ ] New remotes are rate-limited independently of game-logic cooldowns
- [ ] No GUI elements created from code
- [ ] `os.clock()` used for any new timing logic (never `tick()`)
- [ ] Event connections and `task.delay` threads are cleaned up on death/respawn
- [ ] `selene src` and `stylua --check src` pass locally

## Testing

<!-- How did you verify this in Studio? Include repro steps for anything combat/movement related. -->

## Screenshots / clips (if applicable)
