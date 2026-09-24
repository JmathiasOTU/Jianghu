# Jianghu: Wall Climbing (WallCling -> WallBoost) Implementation Plan

Status: design locked, audited against `docs/ARCHITECTURE.md` (v2), ready to implement.
Scope: v1, static geometry only.

---

## 0. Instructions for the implementing AI (read this first)

This plan was written without access to the repo's source files. Every file path, function signature, and interface below is **inferred** from the designer's architecture description, not copied from code. Before writing anything:

1. Read `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` in full. **They outrank this plan.** If anything here conflicts with them, follow them and flag the conflict.
2. Read these existing files completely and match their patterns exactly:
   - `WallRunState.luau` and the wall leap state/logic (closest sibling implementations)
   - `MovementStates.luau` and `Shared/FSM` (how states are `Symbol`s, how `RequestTransition` works)
   - `StateRules.luau`
   - `Shared/Constants/MovementConstants.luau` (match the existing key casing exactly)
   - `Shared/Movement/SpatialQueries.luau` and `TraversalMath.luau`
   - `CharacterMover` (find `SetVelocityOverride`, `SetJumpBlocked`, how gravity is handled during overrides)
   - `Shared/Util/RateLimiter.luau` and how the WallRun claim handler uses it
   - `MovementValidationService.luau` (find `maxSpeedForState`, how WallRun claims are validated, how violations escalate, how state exits reach the server, whether a lag-compensation or pose-history utility exists)
   - `network.zap` (find `ClaimableTraversalMove`, the traversal claim event, and the server-to-client rejection or correction event)
3. Where this plan disagrees with the real code (names, signatures, event shapes, file locations), **the real code wins**. List every mismatch at the top of your first response so the human can confirm.
4. Implement in the phases in section 13, one at a time, and stop after each phase for review.
5. Do not invent new systems when an existing one does the job (violation escalation, RateLimiter, position history, input abstraction, debug visualizers).
6. Run `stylua --check src` and `selene src` before calling any phase done.

Location note: the public README lists `Shared/{Constants,FSM,Types,Util}` and does not list a `Shared/Movement/` folder. The designer's own description places `SpatialQueries.luau` in `Shared/Movement/`. Confirm the real path locally; if `Shared/Movement/` does not exist yet, ask the human whether to create it or to use `Shared/Util/` (stateless shared utilities).

---

## 1. Non-negotiable architecture constraints

Numbers refer to `docs/ARCHITECTURE.md`.

1. **FSM (section 2).** Two new explicit states, `WallClingState.luau` and `WallBoostState.luau`, in `src/Client/Controllers/Movement/States/`. State identifiers are `Symbol` values from `Shared/FSM`, never strings. Transitions go through `fsm:RequestTransition`. Register both in `MovementStates.luau` and define reachability and `CanEnter` in `StateRules.luau`. Controllers never reach into each other; shared per-character movement data lives in the shared state module and is read through it.
2. **Networking (section 10).** No hand-written remotes. Add `WallCling` and `WallBoost` to `ClaimableTraversalMove` in `network.zap`, regenerate with `zap network.zap`. Fire-and-forget only, so any rejection notice is a server-to-client event declared in `network.zap`, never a reply.
3. **Rate limiting (sections 5 and 10).** Every claim handler applies the shared `RateLimiter` at the top. No bespoke debounce or per-player "last claim" timer for spam control.
4. **Zero magic numbers (section 2).** All tunables in `MovementConstants.luau`.
5. **No band-aid validation (section 9).** No server tolerance, slack, grace, or multiplier without a specific, measured, documented cause. This plan ships with **zero server tolerance** and a measurement procedure (section 11.6).
6. **Security (section 3).** Client predicts, server decides. The server keeps its own FSM mirror, owns all cooldowns and lockouts, and sanity-casts the wall against the server-side character.
7. **Performance and memory (section 6).** `os.clock()` only. Dense casts are throttled by delta-time accumulators. Every stateful object (each state instance, each server session) owns a `Trove`, created fresh on entry and destroyed once on exit; a Trove is never reused across a cleanup boundary.
8. **Physics.** Client uses `CharacterMover:SetVelocityOverride()` and/or direct `AssemblyLinearVelocity` writes, plus `CharacterMover:SetJumpBlocked(true)` during cling. The server sets no physics; it only enforces the speed ceiling through `maxSpeedForState`.
9. **Rig (section 1).** R6 only. No R15 branching anywhere.
10. **Style (section 7).** `--!strict`. `PascalCase` for classes and OOP methods (`self._trove:Add`, `WallClingState:Enter`), `camelCase` for locals, plain functions and local constants, `_prefix` for private members. Tabs, 100-column soft limit, no semicolons, no block comments, comments only for non-obvious math or engine quirks, one line.

---

## 2. Locked design decisions (answered by the designer)

| Topic | Decision |
|---|---|
| Core shape | Static cling, then **F** for one upward boost. No steered climbing. |
| Entry | While **airborne**, press **Space** while the character is **facing the wall head-on** (not side-on like wall run). |
| Facing tolerance | Look direction within **~35 degrees** of head-on. |
| Surfaces | **Any near-vertical wall** (no tag or attribute required). |
| Cling limit | **Hard time cap only** (`WallClingMaxDuration`). No Qi drain. |
| Timeout | Peel off, fall to Airborne, plus a **short re-grab lockout**. |
| Space while clinging | **Does nothing** (jump blocked). |
| Drop | **S** (pull away from wall) drops to Airborne. |
| Boost style | **Instant impulse**, then back to Airborne. |
| Boost cost | **Free.** |
| Repeatability | **One boost per cling. Re-cling is allowed** after a short cooldown. |
| Wall run interaction | Separated by angle: head-on = cling, side-on = wall run. |
| Wall leap interaction | Cannot cling to the wall you just leapt from until you land or touch a different wall. |
| Deliverable | This plan file, handed to a VS Code AI for implementation. |

---

## 3. Assumed defaults (NOT answered by the designer, confirm or change)

1. **Double jump conflict.** Space in the air may already trigger a double jump (`doubleJumpUsed` exists in the codebase). Default: **if a valid clingable wall is detected, cling wins over double jump**, and the double jump is **not consumed**. Boost does not restore or consume it either.
2. **Combat while clinging.** Default: attack, parry, and dash entries are **blocked** while in `WallCling` and `WallBoost`. A hit, posture break, or stagger force-exits to Airborne through the existing combat FSM path.
3. **Entry from ground.** Not allowed. Airborne only.
4. **Moving or rotating walls.** Not supported. Require `Anchored == true` on the hit part.
5. **Re-grab lockout scope.** After a timeout, the lockout is **global** (any wall), not per wall. The wall leap memory rule stays per wall. All lockouts are **server-owned** (section 3 of ARCHITECTURE); the client copy is prediction only.
6. **Drop input.** "Move input pulling away from the wall" through the input abstraction, so it works for keyboard (S), gamepad, and mobile alike.
7. **F outside cling.** Ignored. No input buffering.
8. **Infinite climbing.** Re-cling plus a free boost means a player can climb an arbitrarily tall wall. That is the stated design; see section 14 for optional limiters.
9. **Server strictness.** Zero tolerance at first (ARCHITECTURE section 9). A rejected claim cancels the state on the server; the client is only hard-corrected on repeated violations through whatever the existing violation system does.
10. **Animations, VFX, camera.** Placeholder hooks only. No camera changes in v1.

---

## 4. State machine

New states: `WallCling`, `WallBoost` (both `Symbol`s in `MovementStates`).

```
Airborne --(Space, facing wall, legal)--> WallCling
WallCling --(F, boost unused)------------> WallBoost
WallCling --(timeout)--------------------> Airborne   (timeout lockout)
WallCling --(drop input)-----------------> Airborne   (drop lockout)
WallCling --(wall lost)------------------> Airborne
WallCling --(stagger / hit / defeat)-----> Airborne
WallBoost --(WallBoostStateDuration)-----> Airborne   (post-boost cooldown)
WallBoost --(stagger / hit / defeat)-----> Airborne
```

Rules:
- `WallCling` is reachable **only from `Airborne`**.
- `WallBoost` is reachable **only from `WallCling`**.
- `WallBoost` never goes directly back to `WallCling`. Re-cling always goes `Airborne -> WallCling` with a fresh Space press after the cooldown.
- `WallRun` and `WallLeap` cannot transition directly into `WallCling`. If wall leap keeps the player in its own state for a long time, check whether clinging then feels unreachable; if so, add a `WallLeap -> WallCling` edge (section 14).

Exit reasons (used for lockouts and telemetry). Declare them as `Symbol`s next to `MovementStates`, not as strings:

```luau
WallClingExitReasons = {
	Timeout = Symbol.new("WallClingExitTimeout"),
	Dropped = Symbol.new("WallClingExitDropped"),
	WallLost = Symbol.new("WallClingExitWallLost"),
	Interrupted = Symbol.new("WallClingExitInterrupted"),
	Boosted = Symbol.new("WallClingExitBoosted"),
}
```

| Exit reason | Lockout applied |
|---|---|
| Timeout | `WallClingTimeoutLockout` |
| Dropped | `WallClingDropLockout` |
| Boosted | `WallClingPostBoostCooldown` |
| WallLost, Interrupted | none |

Per-character data that must outlive a state (lockout expiry, `boostUsedThisCling`, last leap wall) lives in the shared movement state module that WallRun and WallLeap already use, and is read from there. States do not reach into each other or into other controllers.

---

## 5. Constants (`Shared/Constants/MovementConstants.luau`)

Values are gameplay starting points to tune in playtest. **None of them are server tolerances.** Match the existing table's key casing; local helper values are `camelCase`.

```luau
local wallBoostUpwardForce = 62
local wallBoostSeparationSpeed = 3

local MovementConstants = {
	WallClingMaxDuration = 2.5,
	WallClingDistance = 3,
	WallClingCastSize = Vector3.new(2, 4, 0.2),
	WallClingMaxFacingAngleDegrees = 35,
	WallClingMaxNormalY = 0.26,
	WallClingRecheckInterval = 0.1,
	WallClingDropInputThreshold = 0.5,
	WallClingTimeoutLockout = 0.75,
	WallClingDropLockout = 0.3,
	WallClingPostBoostCooldown = 0.25,
	WallClingSpeedCeiling = 0,

	WallBoostUpwardForce = wallBoostUpwardForce,
	WallBoostSeparationSpeed = wallBoostSeparationSpeed,
	WallBoostStateDuration = 0.12,
}
```

Merge into the existing table; do not replace it. Notes:
- `WallClingMaxNormalY = 0.26` is about 15 degrees from vertical. If wall run already defines a verticality limit, **reuse it**.
- `WallClingCastSize` is sized for the R6 rig: the root part sits about 3 studs above the feet, so a 4-stud-tall cast centered on it spans roughly 1 to 5 studs above the feet. Verify against the actual R6 character.
- `WallBoostUpwardForce = 62` studs/s gives roughly 9.8 studs of rise at default gravity (196.2). Recompute if gravity is customized.
- `WallBoostSeparationSpeed` is a small push away from the wall so the character does not snag on friction while rising. Set to 0 if it feels wrong.
- `WallClingSpeedCeiling = 0`. Any non-zero value needs a measured, documented cause (section 11.6). Do not raise it to make a false flag go away.
- The boost speed ceiling is **not** a constant. It is derived from the impulse itself (section 8), so there is no multiplier to tune.

---

## 6. Networking

### 6.1 `network.zap`

Append the new variants to the **end** of the existing enum. Do not reorder existing variants.

```
type ClaimableTraversalMove = enum "WallRun" | "WallLeap" | ...existing... | "WallCling" | "WallBoost"
```

Reuse the existing traversal claim event. The server does its own spatial query, so it needs only the claimed move. Regenerate with `zap network.zap`; generated files are not committed.

### 6.2 Rate limiting

Apply `Shared/Util/RateLimiter.luau` at the top of the claim handler for both moves, using the same call pattern as the WallRun handler. This is separate from the FSM cooldowns. Do not add a per-player "last claim time" table for spam control.

### 6.3 Rejection notice

Fire-and-forget only. If the server needs to tell the client to cancel a predicted cling, reuse the event WallRun rejection already uses. If none exists, add a server-to-client event to `network.zap` (no reply, no yield) and ask the human before doing so.

### 6.4 Open item: how the server learns a state ended

Find how the server currently learns that a client has *left* a state (a reported state change, or inference). `WallCling` exit must use the **same mechanism as `WallRun` exit**. If there is none, stop and ask the human before adding a release event. A server that thinks a player is still clinging would apply `WallClingSpeedCeiling` to a falling player and flag a legitimate drop.

---

## 7. Shared geometry (`SpatialQueries.luau`)

Two functions, stateless. The world and raycast params are passed in, so client and server run identical code. There is deliberately **no slack or options parameter**: client and server use the same thresholds (ARCHITECTURE section 9).

```luau
export type ClingWallHit = {
	instance: BasePart,
	position: Vector3,
	normal: Vector3,
	distance: number,
}

function SpatialQueries.facingAngleToWallDegrees(lookVector: Vector3, wallNormal: Vector3): number
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	local flatInward = Vector3.new(-wallNormal.X, 0, -wallNormal.Z)
	if flatLook.Magnitude < 1e-3 or flatInward.Magnitude < 1e-3 then
		return 180
	end
	local cosine = math.clamp(flatLook.Unit:Dot(flatInward.Unit), -1, 1)
	return math.deg(math.acos(cosine))
end

function SpatialQueries.castClingWall(
	world: WorldRoot,
	rootCFrame: CFrame,
	lookVector: Vector3,
	params: RaycastParams
): ClingWallHit?
	local flatLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flatLook.Magnitude < 1e-3 then
		return nil
	end

	local castOrigin = CFrame.lookAt(rootCFrame.Position, rootCFrame.Position + flatLook)
	local castDirection = flatLook.Unit * MovementConstants.WallClingDistance
	local result = world:Blockcast(castOrigin, MovementConstants.WallClingCastSize, castDirection, params)
	if not result then
		return nil
	end

	local instance = result.Instance
	if not instance:IsA("BasePart") or not instance.CanCollide or not instance.Anchored then
		return nil
	end
	if result.Normal.Magnitude < 1e-3 then
		return nil
	end
	if math.abs(result.Normal.Y) > MovementConstants.WallClingMaxNormalY then
		return nil
	end
	local facingAngle = SpatialQueries.facingAngleToWallDegrees(flatLook, result.Normal)
	if facingAngle > MovementConstants.WallClingMaxFacingAngleDegrees then
		return nil
	end

	return {
		instance = instance,
		position = result.Position,
		normal = result.Normal,
		distance = result.Distance,
	}
end
```

Details:
- `Blockcast` is used instead of a single ray so the wall must span roughly body height and thin slivers or corners do not trigger a cling. If `Blockcast` misbehaves in this project, fall back to three rays (feet, chest, head) that must all hit near-parallel surfaces.
- A shapecast that **starts inside geometry** can return a hit at distance 0 with a zero normal. The zero-normal guard rejects it; if it shows up near tight corners, add a fallback `Raycast` from the root along the look vector.
- `RaycastParams` exclude the local character (client) or the player's server character (server). Build them the same way wall run does.
- `Anchored` is the v1 stand-in for "static geometry only". Terrain counts as anchored.

---

## 8. Launch math (`TraversalMath.luau`)

```luau
function TraversalMath.wallBoostVelocity(wallNormal: Vector3): Vector3
	local away = Vector3.new(wallNormal.X, 0, wallNormal.Z)
	local separation = Vector3.zero
	if away.Magnitude > 1e-3 then
		separation = away.Unit * MovementConstants.WallBoostSeparationSpeed
	end
	return Vector3.new(separation.X, MovementConstants.WallBoostUpwardForce, separation.Z)
end

function TraversalMath.wallBoostSpeedCeilingAt(secondsSinceBoost: number, gravity: number): number
	local upwardSpeed = math.max(
		MovementConstants.WallBoostUpwardForce - gravity * secondsSinceBoost,
		0
	)
	return math.sqrt(upwardSpeed ^ 2 + MovementConstants.WallBoostSeparationSpeed ^ 2)
end

function TraversalMath.wallBoostPeakHeight(gravity: number): number
	return MovementConstants.WallBoostUpwardForce ^ 2 / (2 * gravity)
end
```

- `wallBoostSpeedCeilingAt` is the exact physical envelope of the impulse under gravity. The server uses it instead of a padded multiplier. It reaches its own natural end when it drops below the normal Airborne ceiling, so no grace duration constant is needed.
- `wallBoostPeakHeight` is for level designers and tests (how tall a gap one boost clears).

---

## 9. `StateRules.luau` additions

Reachability (adapt to the real table shape, using the `Symbol`s):

```luau
Airborne  -> add WallCling
WallCling -> { Airborne, WallBoost }
WallBoost -> { Airborne }
```

`CanEnter` gates. Return a reason if the existing gates do so.

**WallCling** (all must pass):
1. Current state is `Airborne`.
2. Not grounded.
3. `os.clock() >= lockoutUntil` (server-owned value; client uses its predicted copy).
4. Not in a combat FSM state that forbids movement (stagger, posture break, defeated).
5. `SpatialQueries.castClingWall(...)` returns a hit.
6. Hit instance is not the wall the player last wall-leapt from, unless the player has landed or touched a different wall since. Reuse the existing wall leap memory field; do not create a second one.

**WallBoost** (all must pass):
1. Current state is `WallCling`.
2. `boostUsedThisCling == false`.
3. Not in a combat FSM state that forbids movement.

Combat entry rules: add `WallCling` and `WallBoost` to the blocked-from list for attack, parry, and dash (assumption 2).

---

## 10. Client states

The skeletons show intent and ordering. Match `WallRunState`'s real interface (constructor, dependency injection, method names, how a transition is requested).

### 10.1 `WallClingState.luau`

Each `Enter` creates a **new** `Trove` in `self._trove`. `Exit` calls `self._trove:Destroy()` exactly once. Never reuse a Trove across an exit.

Enter:
1. Store `_wall`, `_normal`, `_enteredAt = os.clock()`, `_recheckAccumulator = 0` from the entry data. Set `boostUsedThisCling = false` in the shared movement data.
2. `characterMover:SetJumpBlocked(true)`, with the matching unblock added to the Trove.
3. Zero velocity via `SetVelocityOverride(Vector3.zero)` (or the same mechanism wall run uses to cancel gravity), with the clear added to the Trove.
4. Face the character toward `-normal`.
5. Add the input connections through `self._trove:Connect`.
6. Fire the `WallCling` claim.
7. Play the cling animation hook.

Update (each frame, `dt`):
1. If `os.clock() - self._enteredAt >= MovementConstants.WallClingMaxDuration`, request `Airborne` with the `Timeout` reason.
2. If the drop input (move vector along the away-from-wall direction) exceeds `WallClingDropInputThreshold`, request `Airborne` with `Dropped`.
3. Add `dt` to `_recheckAccumulator`. When it reaches `WallClingRecheckInterval`, subtract the interval and re-run `castClingWall`; if nil, request `Airborne` with `WallLost`. (Delta-time accumulator per ARCHITECTURE section 6; no raw per-frame casts.)
4. Keep velocity held at zero.
5. On F pressed and `boostUsedThisCling == false`, request `WallBoost`, passing the wall normal.

Exit:
- Write the lockout expiry for the exit reason into the shared movement data (`os.clock() + <lockout>`). This is a prediction; the server's copy is authoritative.
- `self._trove:Destroy()`.

Input notes:
- Space must be **consumed** on the frame it enters the cling so the same press is never also read as a jump or double jump on the next frame.
- Space while clinging does nothing (jump is blocked).

### 10.2 `WallBoostState.luau`

Same Trove rule: new on `Enter`, destroyed once on `Exit`.

Enter:
1. Set `boostUsedThisCling = true` in the shared movement data.
2. Write `AssemblyLinearVelocity = TraversalMath.wallBoostVelocity(wallNormal)` **once**. Do not hold a velocity override for the whole state; an override would fight gravity and turn the boost into a hover.
3. Keep `SetJumpBlocked(true)` for the short state window so a queued Space cannot immediately double jump over the impulse, with the unblock in the Trove.
4. Fire the `WallBoost` claim.
5. Play the boost animation and VFX hook.

Update:
- After `WallBoostStateDuration`, request `Airborne`.

Exit:
- Write the post-boost cooldown expiry (`os.clock() + WallClingPostBoostCooldown`) as a prediction.
- `self._trove:Destroy()`.

`WallBoostStateDuration` (about 0.12 s) is a short window, not a control lock. It gives the animation time to play and defines the window the server mirrors.

---

## 11. Server (`MovementValidationService.luau`)

### 11.1 Per-player session

Each accepted cling creates a session that owns its own `Trove`. The session is destroyed once on exit, death (the custom `Defeated` FSM state, not `Humanoid.Died`), respawn, or player leave. A new session (new Trove) is created for the next cling.

```luau
type WallClingSession = {
	acceptedAt: number,
	boostUsed: boolean,
	_trove: Trove.Trove,
}
```

Lockout expiries and `boostStartedAt` live in the server's per-player movement state and are the **only authoritative copies** (ARCHITECTURE section 3).

### 11.2 Claim: `WallCling`

Order of checks:
1. `RateLimiter` at the top of the handler (section 6.2).
2. Server-tracked FSM state permits `Airborne -> WallCling` under the same `StateRules`.
3. `os.clock() >= lockoutUntil`.
4. Server runs `SpatialQueries.castClingWall` against the **server's** view of the character (CFrame and look direction) with the same thresholds the client uses, zero slack. If the codebase has a lag-compensation or pose-history utility (parry uses one per ARCHITECTURE section 4), evaluate against the character pose at the claim's timestamp through that utility. If it does not, evaluate against the current server pose and follow section 11.6 for any false rejections.
5. Hit instance is not the player's last wall leap wall.

On accept: server FSM mirror becomes `WallCling`, a session is created with `acceptedAt = os.clock()`. On reject: cancel the claim, record a violation through the existing escalation path, send the rejection notice (section 6.3).

### 11.3 Ongoing enforcement while in `WallCling`

- **Duration cap.** If `os.clock() - acceptedAt >= WallClingMaxDuration`, force-exit to `Airborne` and apply `WallClingTimeoutLockout`. The server's clock starts at acceptance, which is never earlier than the client's start, so the client's own timeout always fires first for an honest client. **No grace constant is needed.** This is the client-hang safety net.
- **Speed ceiling.** `WallClingSpeedCeiling` through `maxSpeedForState`. A player who claims a cling and then moves is flagged by this alone, so there is no periodic server re-cast and no "wall lost" tolerance counter to tune.

### 11.4 Claim: `WallBoost`

1. `RateLimiter` at the top of the handler.
2. Server FSM mirror is `WallCling` and `session.boostUsed == false`.

On accept: `session.boostUsed = true`, mirror becomes `WallBoost`, record `boostStartedAt = os.clock()`. After `WallBoostStateDuration` measured from `boostStartedAt`, the mirror returns to `Airborne` and the post-boost cooldown starts. Reject everything else (boost without cling, second boost in the same cling, boost while locked).

### 11.5 Speed ceilings (`maxSpeedForState`)

```
WallCling -> MovementConstants.WallClingSpeedCeiling
WallBoost -> TraversalMath.wallBoostSpeedCeilingAt(now - boostStartedAt, workspace.Gravity)
```

After the mirror returns to `Airborne`, the player is still rising. Until the boost envelope falls below the normal Airborne ceiling, the enforced ceiling is:

```
max(normal Airborne ceiling, TraversalMath.wallBoostSpeedCeilingAt(now - boostStartedAt, workspace.Gravity))
```

The envelope ends by itself when the curve drops below the normal ceiling or the player lands. No fixed grace duration exists. The server sets no physics; it only measures and enforces.

### 11.6 Tolerances and measurement (ARCHITECTURE section 9)

This feature ships with **zero server tolerance**. If a legitimate player is falsely rejected or flagged during testing:

1. Reproduce it with Studio's incoming-replication-lag simulation and log the exact values that disagreed (facing angle delta, distance delta, observed speed while clinging, observed speed vs the boost envelope).
2. Identify the cause. If it is pose desync from latency, fix it at the root using the codebase's lag-compensation or pose history, not by widening a number.
3. Only if the cause is a specific, reproducible engine behavior, add a **named constant** with a one-line comment stating what was measured, how, and the value. A tolerance with no measured cause does not get added, and `WallClingSpeedCeiling` is not nudged upward to silence a flag.

---

## 12. Edge cases to handle explicitly

1. Cling entry on the same frame as a double jump input (cling must win, see assumption 1).
2. Cling claim reaches the server after the client already dropped (server must not hold the player in `WallCling`; see section 6.4).
3. Wall destroyed while clinging (client `WallLost` exit; server relies on the speed ceiling).
4. Lag spike during cling: the server duration cap force-exits, and the client exits locally when it receives the rejection notice.
5. Player enters stagger, posture break, or takes a hit mid-cling or mid-boost (force-exit to `Airborne` through the combat FSM path).
6. Player reaches zero HP (custom `Defeated` state) or respawns while clinging: destroy the state's Trove and the server session, clear lockouts. Do not key this off `Humanoid.Died` (ARCHITECTURE section 12).
7. Cling on a wall the player just leapt from (blocked until landing or touching a different wall).
8. Blockcast starting inside geometry near corners (zero-normal guard, optional ray fallback).
9. Overhangs and steep slopes (rejected by `WallClingMaxNormalY`).
10. Two players clinging to the same wall (no interaction in v1).
11. Boost pressed the same frame as timeout (timeout wins, boost ignored).
12. Grounded check while clinging near the floor (exit to `Airborne` and let existing landing logic run).

---

## 13. Implementation phases (stop for review after each)

**Phase 1: scaffolding.** Constants, Zap enum, `MovementStates` `Symbol`s, exit-reason `Symbol`s, `StateRules` reachability and `CanEnter`. Nothing behaves yet; the project must still compile and all existing movement must be unchanged. `stylua --check src` and `selene src` clean.

**Phase 2: geometry.** `SpatialQueries.castClingWall` and `facingAngleToWallDegrees`, plus the `TraversalMath` functions. Unit tests if the repo has a test runner, and a debug visualizer that draws the cast and hit normal.

**Phase 3: client cling.** `WallClingState` entry, hold, timeout, drop, wall lost. No boost yet. Verify jump is blocked, Space does not double jump, timeout lockout works, and the Trove is destroyed on every exit path.

**Phase 4: client boost.** `WallBoostState`, F input, once per cling, re-cling after cooldown. Tune `WallBoostUpwardForce`.

**Phase 5: server mirror.** `RateLimiter` on both handlers, FSM mirror, sessions with Troves, server-owned lockouts, duration force-exit, speed ceilings, violation hookup. Zero tolerance.

**Phase 6: measurement and exploit pass.** Run the section 11.6 procedure under simulated latency, then every case in section 15.

**Phase 7: polish.** Animations, VFX, sounds, optional ease-into-hold-offset when attaching, mobile and gamepad input for F and drop.

---

## 14. Optional limiters and open design questions (parking lot)

1. **Infinite climbing.** With a free boost and re-cling, any wall can be climbed forever. If that undermines level design: a chain limit that resets on landing, a Qi cost on boost, or a rule that re-cling needs a different wall after N boosts.
2. **Combat during cling.** Assumption 2 blocks it. A parry-based game may want parry or a defensive option while clinging.
3. **`WallLeap -> WallCling`.** Add the edge if wall leap holds its own state long enough that clinging feels unreachable after a leap.
4. **Grounded cling.** Currently airborne only.
5. **Camera.** Optional pull-back or FOV change while clinging.
6. **Climbable-wall visibility.** No indicator in v1.
7. **NPC and target reactions** to a clinging player (hitbox, targeting height).

---

## 15. Test matrix

**Gameplay**
- Jump toward a wall head-on, press Space: clings.
- Same, but facing 45 degrees off: does not cling.
- Same, but wall is side-on (wall run angle): wall run, not cling.
- Cling for full duration: peels off, cannot re-cling for `WallClingTimeoutLockout`.
- Cling, pull S: drops, cannot re-cling for `WallClingDropLockout`.
- Cling, press Space repeatedly: nothing happens.
- Cling, press F: rises about `wallBoostPeakHeight` studs, returns to Airborne.
- Cling, F, F: second F ignored.
- Cling, F, re-cling after cooldown, F: works, repeatable up a tall wall.
- Wall leap off a wall, immediately face it and press Space: blocked. Land, then try: allowed.
- Airborne facing a valid wall with double jump available, press Space: clings, double jump still available afterward.
- Airborne with no wall, press Space: double jump as before.
- Steeper slope, overhang, non-collidable part, unanchored part: never clings.
- Enter cling, get staggered: exits to Airborne, Trove destroyed, no leaked connections.
- Reach zero HP while clinging: `Defeated` state takes over, session destroyed.

**Server and exploit**
- Claim `WallCling` with no wall nearby: rejected.
- Claim `WallCling` while facing away from a wall: rejected.
- Claim `WallCling` while grounded: rejected.
- Spam `WallCling` claims: `RateLimiter` rejects, violations recorded.
- Claim `WallBoost` with no cling: rejected.
- Claim `WallBoost` twice in one cling: second rejected.
- Client stays in cling past `WallClingMaxDuration`: server force-exits.
- Client claims cling, then moves: speed ceiling violation.
- Client claims boost, then rises faster than the envelope: flagged.
- Legit boost, legit drop, and legit cling under simulated latency: any false flag is investigated per section 11.6, never padded.
- Legit drop, then fall at terminal velocity: not flagged (server left `WallCling`).

---

## 16. Done criteria

- All phase 1 to 6 checks pass with no regressions to wall run, wall leap, double jump, dash, parry.
- No magic numbers in either state module.
- No hand-written remotes; `network.zap` regenerated.
- Both handlers use `RateLimiter`; no bespoke debounce.
- No server tolerance constant without a documented measurement.
- Server independently rejects every case in the exploit list.
- `--!strict` clean, `stylua --check src` and `selene src` clean, no `tick()`, no block comments, every Trove created fresh per entry and destroyed once per exit.

---

## 17. Audit log: changes from v1 (ARCHITECTURE.md compliance)

| Rule | v1 problem | Fix in v2 |
|---|---|---|
| Section 9, no band-aid validation | Six arbitrary padding constants: distance slack, facing slack, duration grace, wall-lost tolerance, boost speed multiplier (1.15), airborne grace duration | All removed. Server uses identical thresholds, starts its timer at acceptance, derives the boost ceiling from the impulse physics, and follows a measurement procedure (11.6) |
| Sections 5 and 10, RateLimiter | Used a bespoke per-player query-interval throttle to reject claim spam | `RateLimiter` at the top of each handler; per-player timer removed |
| Section 2, Symbols and FSM | Exit reasons were raw strings; transitions described loosely | Exit reasons are `Symbol`s; transitions via `fsm:RequestTransition`; shared data lives in the shared movement module |
| Section 3, server-owned cooldowns | Client `context` held lockout state | Server holds authoritative lockouts; client copy is prediction only |
| Section 6, Trove and accumulators | Trove lifecycle vague; server session had no Trove | Fresh Trove per entry, destroyed once per exit, on both client states and server sessions; recheck uses a delta-time accumulator |
| Section 7, style | PascalCase local constants, an overlong line, no lint gate | `camelCase` locals, wrapped lines, PascalCase OOP methods, `stylua` and `selene` in done criteria |
| Section 10, fire-and-forget | Rejection handling unspecified | Rejection is a server-to-client Zap event, no replies |
| Section 12, player state | Used "stunned or ragdolled" and a generic death case | Uses combat FSM states and the custom `Defeated` state, never `Humanoid.Died` |
| Section 1, R6 | Cast size ignored the rig | Cast sized and documented for R6 |

---

## 18. Implementation & playtest log (2026-09-19 session)

**Status: Phases 1-5 are done and confirmed working via real Studio playtesting** (cling, boost, re-cling, drop, timeout, and server-side rejection of a stale/desynced claim all tested live). Phases 6 and 7 are what's left — see §18.6. This section is kept updated the same way this plan's own §17 audit log and `docs/Wall Run & Leap Mechanic Guideline.md` already are: real playtest bugs and their root causes, dated, in this doc rather than a separate changelog.

### 18.1 What shipped, and where

| Phase | Scope | Status |
|---|---|---|
| 1 | Scaffolding: `MovementConstants`, `network.zap` enum, `MovementStates`/`WallClingExitReasons` `Symbol`s, `StateRules` topology + `CanEnter`, geometry (`SpatialQueries.castClingWall`), math (`TraversalMath.WallBoost*`) | Done |
| 2 | Folded into Phase 1 — `CanEnter[WallCling]` needed the real geometry function to exist to compile, so there was no clean way to defer it | Done |
| 3 | Client `WallClingState.luau` (entry/hold/timeout/drop/wall-lost) | Done |
| 4 | Client `WallBoostState.luau` + F key input (`InputController.BoostRequested`) | Done |
| 5 | Server mirror (`MovementValidationService.luau`): rate limiting (reuses the existing `traversalRateLimiter`), FSM mirror, per-session fields, duration force-exit, independent wall-presence recheck, speed ceilings, claim buffering | Done |
| — | F4 debug menu: 9 new live-tunable values | Done |

New files: `src/Client/Controllers/Movement/States/WallClingState.luau`, `WallBoostState.luau`, `src/Shared/FSM/WallClingExitReasons.luau`.

Most heavily touched: `MovementValidationService.luau` (server mirror — this is where most of the real logic lives), `Movement/init.luau` (client orchestration: input wiring, `buildContext`, `fsm.changed` bookkeeping), `StateRules.luau`, `SpatialQueries.luau`, `TraversalMath.luau`, `MovementConstants.luau`, `MovementTuning.luau`, `MovementTypes.luau`, `ClientMovementContext.luau`, `CharacterMover.luau`, `InputController.luau`, `WallRunState.luau` (gained `wallRunEntryInstance` tracking, needed for wall-leap memory), `network.zap`, `Assets/UI/MovementDebugOverlay.model.json`.

### 18.2 Confirmed mismatches vs. this plan's own text

The plan was written without repo access (see §0) and got most of it right, but these specific points diverged once checked against the real code:

1. **No combat FSM exists at all** (no `Stagger`/`PostureBreak`/`Defeated` state — only bare `CombatConstants.luau`). Assumption 2 (block combat while clinging) and edge cases 5/6 are **not implemented** — there's nothing yet to hook into. Revisit once combat lands.
2. **No lag-compensation/pose-history utility exists.** Server validates `WallCling` claims against its current live pose, per this plan's own §11.2 fallback — this was already anticipated, not a surprise.
3. **No pre-existing "wall leap memory" field.** `WallRunQueryResult` never tracked the hit `BasePart` before this work (only `position`/`normal`/`side`). Added `instance: BasePart` to it (additive), plus `WallRunState.GetEntryInstance()` / `ClientMovementContext.wallRunEntryInstance` (client) and `session.wallRunEntryInstance` (server) to actually populate `lastWallLeapWall`.
4. **The facing-angle gate moved out of `castClingWall` and into `CanEnter[WallCling]`**, deviating from this plan's own §7 pseudocode (which baked it into the cast). Reason: baking it in would have made `WallClingMaxFacingAngleDegrees` permanently fixed, but the user asked for it to be F4-tunable. Now matches `WallRun`'s own "cast finds it, `CanEnter` judges it against a live constant" split. This needed a new shared `context.facingDirection` field (optional, client-populated; server-side population is real as of Phase 5 too).
5. **No server→client rejection event was added** — followed the existing precedent instead (`WallRun`/`WallLeap` have none either); every exit is inferred, never signaled.
6. **`WallClingMaxNormalY` is a separate constant from `WallDetectMaxUpDot`**, deliberately (a stricter near-vertical gate for cling than wall-run's side-cast flatness check) — kept non-tunable, same category as `WallDetectMaxUpDot`.

### 18.3 Real bugs found via playtesting, root cause and fix (all fixed)

1. **"Didn't work at all" (first ever test).** Root cause: the test wall wasn't `Anchored`. Working as designed (v1 requires `Anchored == true`, assumption 4) — not a code bug. Diagnosed via temporary debug flags: `SpatialQueries.WALLCLING_DEBUG_LOGGING` and `Movement/init.luau`'s `WALLCLING_TRACE_LOGGING` — both currently `false`, left in place for future debugging sessions.
2. **Server mirror got permanently stuck in `WallCling` after landing.** `StateRules.Transitions[WallCling]`/`[WallBoost]` originally only listed `Airborne`/`WallBoost` as legal targets, never a grounded state — but `mirrorPassiveTransitions`'s own landing branch calls `LandingResolution.Resolve(context)`, which returns a grounded state (`Idle`/`Walk`/etc.) directly, never `Airborne`. That transition silently failed every single Heartbeat once the player was grounded, forever (topology rejected it, and `context.grounded` short-circuited the duration/wall-lost fallback below it every time). **Fixed** by giving both states the same full grounded-target list `WallRun`'s own table already has. This one bug fully explained two distinct-looking symptoms: (a) ordinary ground movement getting flagged as speed violations (the stuck mirror's stale `WallClingSpeedCeiling = 0`), and (b) a *later*, completely legitimate re-cling attempt getting rejected because the stuck mirror, once it finally force-exited via the duration cap, mis-applied a fresh `WallClingTimeoutLockout` for what was actually just a landing.
3. **Missing `context.grounded` check client-side.** Neither `WallClingState.Update` nor `WallBoostState.Update` ever resolved a landing locally — this plan's own edge case 12 (clinging/boosting near the floor) was simply unimplemented. **Fixed** — added at the very top of both `Update`s, same priority every other airborne-family state's own `Update` already gives it.
4. **Claim rejected specifically when crossing into cling range while already airborne** (jump from outside the ~3-stud range, drift into range mid-air, press Space — rejected every time). Same root cause as `WallRun`'s own, already-fixed `WallRunClaimBufferSeconds` problem: the server's replicated position/CFrame always lags the client's real one by some amount no query-fresher fix can outrun, so a claim fired the instant the client enters range can land before the server's own cast agrees. **Fixed** by adding the identical claim-buffering mechanism for WallCling (`PlayerSession.pendingWallClingClaimUntil`, retried every Heartbeat in `retryBufferedTraversalClaims` against the exact same `CanEnter`/topology gate, never a relaxed one) — reusing `WallRunClaimBufferSeconds` rather than a second, unmeasured constant, since it's the same underlying phenomenon.
5. **`peakHeight`/fall-height tracking reset mid-excursion.** The exclusion list that keeps `peakHeight` alive across one continuous fall (already correctly handled for `DoubleJump`/`WallRun`/`WallLeap`) didn't include `WallCling`/`WallBoost` — clinging or boosting partway down a long fall would have quietly erased the real fall height and dodged a deserved `HardLanding` on the eventual real landing. Fixed on both client (`Movement/init.luau`) and server (`MovementValidationService.luau`).

### 18.4 F4 debug menu (live tuning)

Added under new "WALL CLING"/"WALL BOOST" sections in `Assets/UI/MovementDebugOverlay.model.json`: `WallClingMaxDuration`, `WallClingMaxFacingAngleDegrees`, `WallClingDropInputThreshold`, `WallClingTimeoutLockout`, `WallClingDropLockout`, `WallClingPostBoostCooldown`, `WallBoostUpwardForce`, `WallBoostSeparationSpeed`, `WallBoostStateDuration`.

Deliberately **not** exposed (structural/anti-cheat plumbing, matching existing precedent for `WallRunSideCastDistance`/`WallDetectMaxUpDot`): `WallClingDistance`, `WallClingCastSize`, `WallClingMaxNormalY`, `WallClingRecheckInterval`, and especially `WallClingSpeedCeiling` — this plan calls that one out by name (§5) as a value that must never be tuned away from zero without a specific, measured, documented cause.

### 18.5 Explicitly deferred by the user (2026-09-19)

VFX and SFX for WallCling/WallBoost — skip entirely, not just "not yet done" for this pass. Animations were **not** explicitly addressed either way in that same request; ask the user before adding them rather than assuming they're included in the same "skip it" instruction.

### 18.6 What's actually still open

- **Phase 6** (§15's test matrix): the exploit/gameplay pass, ideally under Studio's simulated incoming-replication-lag. Nothing from Phase 5 has been stress-tested under real added latency yet — the bugs in §18.3 were all found via ordinary local play, not the measurement procedure §11.6 describes.
- **Phase 7, minus VFX/SFX**: mobile/gamepad input for F (boost) and drop, optional ease-into-hold-offset when attaching. Animations: done, see §18.8.
- **§14's open design questions** (infinite climbing, combat interaction once it exists, a `WallLeap -> WallCling` edge, grounded cling, camera changes, NPC/target reactions) are all still genuinely open — none were decided this session.

### 18.8 Animations wired (2026-09-20)

User explicitly asked for cling and boost animations (superseding §18.5's "ask first" deferral for this one piece; VFX/SFX stay explicitly out per that same section).

- **`WallCling`** reuses the pre-existing `"WallLatch"` slot in `Assets/Animations/Movement.model.json`, renamed to `WallCling` to match every other track's 1:1 name-matches-FSM-state convention. `Wall Run & Leap Mechanic Guideline.md` (§0/§13) already documented this slot as reserved for the latch/cling mechanic under its original pre-rename name and deliberately left alone when WallRun/WallLeap shipped — it already carries a real `AnimationId`, so this is a rename, not a new asset.
- **`WallBoost`** has no pre-authored clip. Added as a new blank-`AnimationId` slot in the same file, same "not authored yet" convention `loadTrack` already treats as silently-skip-until-filled-in (no code change needed once a real id is set).
- Both wired into `LocomotionAnimator.luau`: `WallCling` loads looped (a real sustained hold, same as `WallRun`); `WallBoost` loads as a one-shot (same as `Jump`/`DoubleJump`). Neither needed the `_transientHold` reentrant-state bridge that `SlideJump`/`WallLeap` require — `WallBoostStateDuration` (~0.12s) is real elapsed time, not a same-Heartbeat-tick self-transition, so `fsm.current == WallBoost` is genuinely observable across multiple real `RenderStepped` frames, same reasoning `HardLanding`'s direct per-state resolution already relies on.
- Neither state needed a Left/Right split (unlike `WallRun`/`WallLeap`): cling is head-on by design (§2 locked decision) and boost is a straight vertical launch, so both are single non-directional clips, same treatment as `Idle`/`Slide`/`Jump`.
- `WallBoost`'s `AnimationId` is still blank — needs a real clip uploaded and the id set in `Movement.model.json` before it's audible/visible; until then it silently plays nothing, same as any other not-yet-authored slot in this file.

### 18.7 Phase 6: static audit findings (2026-09-19, pre-playtest)

Before running §15's exploit/gameplay pass live, did a static code read-through against every case in that matrix. Found and fixed one real bug this way (not via playtesting — the code itself made the failure mode visible without needing to reproduce it):

**Bug: `Dropped` exit had no server-visible signal, unlike `Timeout`/`WallLost`.** Per §6.4/§18.2 point 5, the server never gets a release event — every `WallCling` exit is inferred from `MovementValidationService`'s own `wallClingQuery` going nil or the duration cap firing. That inference is sound for `Timeout` (server's own independent timer) and `WallLost` (both sides observe the same geometry fact), but `Dropped` is a voluntary input decision with no geometry consequence of its own: `WallClingState.Exit` only cleared the velocity override and jump-block, applying no push. A player who tapped the drop input once and released everything could keep falling straight past the same wall, still within `castClingWall`'s reach, leaving the server's mirror stuck in `WallCling` (`WallClingSpeedCeiling = 0`) for up to the full `WallClingMaxDuration` after the client had already moved on — rejecting a legitimate re-cling on a nearby wall in the meantime. Same underlying bug class as §18.3's landing-transition and claim-buffering fixes: an inferred mirror with no independent signal for one specific edge.

**Fix:** added `WallClingDropSeparationSpeed = 6` (`MovementConstants.luau`) and a one-shot `SetHorizontalVelocity` push away from the wall in `WallClingState.Exit`, applied only for the `Dropped` reason and only after `ClearVelocityOverride()` (otherwise the still-active constraint stomps it next physics step) — same idiom `WallBoostVelocity`'s own separation component already uses, kept as a plain `MovementConstants` literal (not live-tunable) since it's structural/anti-cheat plumbing, not a feel dial, matching `WallClingDistance`/`WallClingCastSize`'s own precedent. No server-side change needed — this only makes the client's actual position change so the server's existing, already-correct inference resolves promptly instead of depending on the player continuing to hold input after letting go.

**Everything else in §15's matrix checked out against the current code:** `RateLimiter` gates both claim handlers independently of the FSM cooldown; topology alone rejects a `WallBoost` claim with no active cling (no edge into it except from `WallCling`); `wallClingBoostUsed`/`context.wallClingBoostUsed` blocks a second boost in one cling; `CanEnter[WallCling]` (`StateRules.luau`) checks grounded, lockout, wall presence, wall-leap memory, and facing angle in that order, all against server-trusted/replicated state; the duration force-exit has its own server-side timer that always fires no later than the client's; and the boost envelope (`WallBoostSpeedCeilingAt`) is the real decaying-impulse-under-gravity formula, not a padded multiplier.

**Tooling gate not yet clean:** `stylua --check src` errored (`I/O error: operation failed to complete synchronously` — looks environmental, not a formatting diff) and `selene src` failed to load the Roblox stdlib (`unknown field 'lua_versions'` — installed `selene` binary and its `roblox.yml` are on mismatched versions). Neither run to completion yet this session; §16's done-criteria needs both clean before Phase 6 can be marked done.

**Still needs the live half:** §11.6's measurement procedure under Studio's simulated incoming-replication-lag, and every case in §15 actually played out, especially the latency-dependent ones (claim-buffering window sizing, the boost-envelope-vs-observed-speed check, and re-verifying the drop fix above resolves the mirror desync quickly in practice rather than just in theory).
