# Wall Run & Wall Leap — AI Implementation Guide

Step-by-step build guide for an AI agent (or a human following the same
checklist) implementing Wall Run and Wall Leap **from scratch** in Murim
Ascent. Scope is deliberately narrower than the old attempt: **WallRun and
WallLeap only** — no WallClimb, no WallLatch. Read this whole document before
writing code; it exists so the agent doesn't have to re-derive decisions
`docs/MOVEMENT.md` already settled, and doesn't repeat the mistake that got
the last attempt reverted.

Update `docs/MOVEMENT.md` (not this file) as the real build progresses —
this guide is the plan, `MOVEMENT.md` is the living record of what actually
got built, same split the project already uses for every other phase.

---

## 0. Why this is a from-scratch redo, not a revival

A WallRun/WallClimb/WallLatch pass was built and then reverted wholesale on
2026-09-17 (`docs/MOVEMENT.md` §13). Read that section before touching code.
The two load-bearing facts to carry forward:

1. **Wall-run detection needs a side raycast, not a forward one.** A forward
   low+high raycast pair (the "is there a wall dead ahead" check used for
   latching) starves for wall-running specifically, because you approach a
   wall to run along it at a shallow angle, moving mostly *parallel* to its
   surface — a forward ray routinely never touches it. The reference that
   actually worked cast along the root part's own `CFrame.RightVector` (and
   its mirror) instead: first hit wins, whichever side the wall is on.
2. **Don't build more than the current move needs.** The reverted pass built
   WallRun, WallClimb, and WallLatch together, plus a full tunable-constants
   surface, before any of the three had proven out end-to-end. This guide
   scopes to WallRun + WallLeap only, on purpose — WallClimb/WallLatch stay
   in `docs/MOVEMENT.md`'s **Deferred** section until this pair is playtested
   and solid.

---

## 1. Decisions this guide is making up front (don't re-litigate mid-build)

These answer the "ask clarifying questions" framing the design brief raised.
Answered here so the agent can build in one pass instead of stopping to ask:

| Question | Decision | Why |
|---|---|---|
| Raycasting vs. shapecasting for wall detection | **Raycasting** — a side ray (WallRun probe) plus a short-lived forward ray only at the moment of Leap input (to read the wall's exit normal). | Matches the project's existing `SpatialQueries` idiom (`QueryWall`/`QueryLedgeAbove` are plain raycasts) and the one probe that's already proven to work. Shapecasting adds a whole-body sweep the mechanic doesn't need — a wall run only cares about one point on the wall at torso height, not the character's full silhouette. |
| Curved walls / corners | **Not handled specially in v1.** A wall run ends the instant the side probe stops hitting (wall lost → normal Airborne exit, same as every other traversal state's "lost the surface" exit). No wraparound logic, no corner-following. | The design brief doesn't require it, `docs/ARCHITECTURE.md` §9 forbids padding tolerances for unmeasured cases, and "don't design for hypothetical future requirements" is a house rule. Revisit only if playtesting shows corners are common enough to need `QueryWallRun`'s dual-side cast to hand off from one wall to another. |
| Custom movers (`LinearVelocity`/`AlignOrientation`) vs. raw `AssemblyLinearVelocity` | **`LinearVelocity`, horizontal-only**, via `CharacterMover`'s existing `SetHorizontalVelocity` constraint idiom. No `AlignOrientation` — facing already rides on `FacingController`'s camera-relative override, untouched by this feature. | This is exactly the pattern `SlideState`/the reverted `WallRunState` already used successfully (`docs/MOVEMENT.md` §12/§13) — a proven, Trove-owned, per-life constraint, not a new mover class. Writing to `AssemblyLinearVelocity` directly would bypass `CharacterMover`'s narrow interface, which `docs/ARCHITECTURE.md` §2 forbids (states never touch Roblox physics APIs directly). |
| Gravity during the run | **Untouched — no hover.** Wall running is a horizontal skim while still falling; the run ends via `WallRunMaxDurationSeconds` or losing the wall before gravity would pull the player off anyway. | Same call the reverted design made (§13) and nothing in the brief asks for a vertical hold. A vertical hold is real added complexity (needs `AlignPosition`/a vertical constraint) for a "gravity-defying" *feel* that horizontal-skim + a graceful leap arc already delivers without it. |
| Server validation strategy | **Claimed-transition model** (DoubleJump's pattern, not Slide's passive-mirror one) — see §5. | Wall running is explicitly the highest-value exploit surface in the brief; a passive mirror can't independently confirm "the player is actually touching real geometry" the way a server-side raycast + claim-timestamp model can. |

If you disagree with any row above, change it **before** starting §6's
checklist, and update this table so the doc stays honest about what was
actually decided.

---

## 2. Feel target (Qinggong, not parkour)

- Entry should read as a deliberate technique, not a physics accident:
  the character's facing snaps to run along the wall the instant the state
  is entered (via the same `FacingController` override every other locked
  state already uses), not a Western-parkour hunch/lean.
- No deceleration into the wall run — speed carries in at whatever it was
  and holds at `WallRunSpeed` for the duration, since a martial artist
  running up/along a wall doesn't visibly fight friction.
- The leap is one clean impulse, not a scripted flip: a fixed launch speed
  along a blended "wall's outward normal + player's current facing"
  direction (§4), so it reads as pushing off the wall with intent rather
  than just being thrown off it.
- No screen shake, no camera FOV punch, no particle trail for v1 — the
  brief's "fluid, gravity-defying" ask is a movement-math problem to solve
  first; juice is a separate, later pass once the raw motion feels right in
  Studio.

---

## 3. FSM mapping

Two new states, `WallRun` and `WallLeap` (`Shared/FSM/MovementStates.luau`),
following the **claimed transition** pattern (`docs/MOVEMENT.md` §11's
DoubleJump, not §9's Slide):

```
Airborne --(side wall found + CanEnter)--> WallRun --(Jump pressed)--> WallLeap --> Airborne
Airborne --(mid-run, wall lost / duration cap / mid-run landing)--> Airborne / grounded state
```

- **`WallRun.CanEnter`** (`Shared/Movement/StateRules.luau`): airborne, not
  already in `WallRun`/`WallLeap`, and `context.wallRunQuery` (populated
  before the check, never inside `StateRules` — see §4) reads a hit within
  `WallRunSideRayLength` whose normal passes the same "close to horizontal"
  flatness check `QueryWall` already uses (rejects a ramp/ceiling read as a
  wall).
- **`WallLeap.CanEnter`**: only reachable from `WallRun`, requires Jump
  input and a live `wallRunQuery` hit at the moment of the request (the
  server re-derives this independently — see §5, never trusts the client's
  claim that a wall was there).
- **Entry is polling for `WallRun`, discrete for `WallLeap`** — same split
  DoubleJump/Airborne already establish: `AirborneState.Update` tries
  `RequestTransition(WallRun, context)` every Heartbeat while airborne (a
  harmless no-op when `CanEnter` fails); `WallLeap` is only ever requested
  from the Jump-input handler while `fsm.current == WallRun`, exactly the
  way the reverted design's `ClimbJump` branched off the ordinary jump
  handler (`docs/MOVEMENT.md` §13) — reuse that branch shape, not a new
  input path.
- **Exits from `WallRun`** (all land in `Airborne`, resolved the same
  "mid-move landing" way SlideJump/DoubleJump already do —
  `AirborneState.ResolveLandingTarget`, never a bare state assignment):
  wall lost (probe stops hitting), `WallRunMaxDurationSeconds` elapsed, or a
  mid-run landing on real ground.
- **`WallLeap` is a one-shot launch, not a held state** — apply the impulse
  in `Enter` (via `CharacterMover.SetHorizontalVelocity` +
  `SetVerticalVelocity`, the same two-call pattern the reverted WallClimb
  exits used, §13) and transition straight into `Airborne` in the same call,
  synchronously — the "no real physics step in between" problem
  `SlideJumpState`/the old `ClimbJump` already solved this exact way.

### Module layout (new files only; everything else is additive edits)

```
Shared/
  FSM/MovementStates.luau        -- + WallRun, WallLeap Symbols
  Movement/
    StateRules.luau              -- + CanEnter/topology for both
    SpatialQueries.luau          -- + QueryWallRun (side raycast)
    TraversalMath.luau           -- + WallRunTangentVelocity, WallLeapVelocity
  Types/MovementTypes.luau       -- + wallRunQuery context field
  Constants/MovementConstants.luau -- + every numeric value below, nothing inline

Client/Controllers/Movement/
  States/
    WallRunState.luau            -- new
    WallLeapState.luau           -- new
  init.luau                      -- + throttled wallRunQuery probe on Heartbeat,
                                     + Jump-input branch to WallLeap while in WallRun
  AirborneState.luau              -- + RequestTransition(WallRun) polling attempt

Server/Services/
  MovementValidationService.luau -- + WallRun/WallLeap claim branches,
                                     + server-side wallRunQuery probe,
                                     + maxSpeedForState entries
```

---

## 4. Math model

### 4.1 Wall detection (`SpatialQueries.QueryWallRun`)

Cast two rays every throttled tick (`WallDetectRaycastThrottleSeconds`,
reuse the existing accumulator idiom — do not sample every raw Heartbeat):

```
rightHit = Raycast(rootPart.Position, rootPart.CFrame.RightVector * WallRunSideRayLength)
leftHit  = Raycast(rootPart.Position, -rootPart.CFrame.RightVector * WallRunSideRayLength)
hit = rightHit or leftHit   -- first one found wins; track which side for the tangent sign
```

A hit only counts as a wall if its normal passes the same flatness check
`QueryWall` already uses:

```
isFlat = math.abs(hit.Normal:Dot(Vector3.yAxis)) < WallDetectMaxUpDot
```

(`WallDetectMaxUpDot` is already a constant from the reverted pass's
design — reuse the value/name, don't invent a second one.)

Store the result as `context.wallRunQuery: {hit: RaycastResult?, side: "Left" | "Right"}`,
populated by the client/server probe **before** calling into `StateRules`,
same "context field, not computed inside StateRules" rule the original
`wallQuery`/`wallRunQuery` fields already established.

### 4.2 Wall-run tangent velocity (`TraversalMath.WallRunTangentVelocity`)

Given the wall's normal and the player's current facing/move direction,
project out the into-the-wall component and run along what's left:

```
tangent = (moveDirection - moveDirection:Dot(wallNormal) * wallNormal).Unit
outputVelocity = tangent * WallRunSpeed
```

If `moveDirection` is near-zero (player holding no lateral input, just
carrying momentum forward into the run), fall back to the character's
current flat `AssemblyLinearVelocity` direction instead of `moveDirection`
so the run has a direction to project at all — never divide by a
near-zero vector's magnitude.

Apply via `CharacterMover.SetHorizontalVelocity(outputVelocity)`
(`LinearVelocity`, horizontal-only mask, same idiom Slide uses). Leave
vertical motion to gravity entirely — no vertical constraint, no hover.

### 4.3 Wall leap velocity (`TraversalMath.WallLeapVelocity`)

At the moment `WallLeap` is entered, blend the wall's outward normal with
the player's current facing so the leap reads as "push off the wall in the
direction you're already going," not a pure perpendicular bounce:

```
launchDirection = (wallNormal * WallLeapNormalWeight + facingFlat * (1 - WallLeapNormalWeight)).Unit
horizontalVelocity = launchDirection * WallLeapSpeed
verticalVelocity = WallLeapUpwardSpeed
```

`WallLeapNormalWeight` (0–1, start around 0.6 — mostly away from the wall,
with enough forward carry to feel graceful rather than a flat sideways
shove) is itself a constant, tuned in Studio, not hardcoded inline.

Apply both components in `WallLeapState.Enter` via
`CharacterMover.SetHorizontalVelocity` + `SetVerticalVelocity` in the same
call, then transition to `Airborne` synchronously — see §3.

---

## 5. Server validation strategy

Wall running is explicitly called out in the brief as a major exploit
surface (fly-hacking, infinite wall-running). This mirrors DoubleJump's
claimed-transition model (`docs/MOVEMENT.md` §11), not Slide's passive
mirror, because a passive mirror alone can't independently confirm real
geometry is present — it can only watch the client's own reported state.

1. **Server runs its own `QueryWallRun` probe, independently.** Every
   airborne session gets a server-side throttled raycast accumulator
   (`MovementValidationService.updateWallRunQuery`, same shape as the
   reverted design's `updateWallQuery`) — never trusts a client-reported
   "I'm touching a wall" claim. This is the literal "sanity raycast against
   real geometry near the character's server position" `docs/ARCHITECTURE.md`
   §3 requires for any spatial claim.
2. **`WallRun`/`WallLeap` are claimed transitions**, dispatched through the
   same `ClaimableTraversalMove` remote enum DoubleJump/Slide already use
   (`network.zap`), sharing DoubleJump's existing `traversalRateLimiter`
   budget — no new limiter needed. The server never accepts a claim
   without its own `wallRunQuery` (or, for Leap, a live `WallRun`-state
   mirror plus a fresh wall hit) independently confirming legality at claim
   time.
3. **Duration cap is server-owned, not client-trusted.** `PlayerSession`
   stores `wallRunEnteredAt` (server's own `os.clock()`, never a
   client-sent timestamp — same pattern `runEnteredAt` already uses).
   `mirrorPassiveTransitions` force-exits `WallRun` the instant
   `os.clock() - session.wallRunEnteredAt > WallRunMaxDurationSeconds`,
   independent of whatever the client claims — this is what actually
   prevents infinite wall-running, not a client-side timer a modified
   client could just ignore.
4. **Wall-loss is enforced server-side too.** `mirrorPassiveTransitions`
   checks the server's own `wallRunQuery` every tick while mirrored as
   `WallRun`; the instant the server's own probe stops hitting a flat wall,
   it force-exits to `Airborne` regardless of what the client is doing —
   this is the actual anti-fly-hack backstop (a client claiming to still be
   wall-running against a wall the server's raycast says isn't there gets
   corrected, not trusted).
5. **Speed sanity reuses the existing generic mechanism.** Add `WallRun` →
   `WallRunSpeed` and `WallLeap` → a launch-speed-derived ceiling to
   `maxSpeedForState` — `enforceSpeedSanity`/`effectiveMaxSpeed`'s
   landing-momentum grace (`docs/MOVEMENT.md` §12) already generalizes over
   "the cap decreased at the last transition," so `WallLeap → Airborne`
   gets that grace for free, no new code needed for it specifically.
6. **False-flag avoidance:** don't add a tolerance you can't point to a
   measured cause for (`docs/ARCHITECTURE.md` §9). If early playtesting
   shows legitimate wall-runs getting corrected, the fix is almost always
   "the server's raycast throttle interval is coarser than the client's,"
   not "widen the speed tolerance" — check the throttle intervals match
   before touching any multiplier.

---

## 6. Build checklist (in order)

Follow this order — each step should compile/require cleanly before moving
to the next. Do not build WallClimb/WallLatch alongside this; they stay
deferred (`docs/MOVEMENT.md`'s **Deferred** section).

1. **Constants** — add every numeric value named in §4/§5 to
   `Shared/Constants/MovementConstants.luau`: `WallRunSpeed`,
   `WallRunMaxDurationSeconds`, `WallRunSideRayLength`,
   `WallDetectMaxUpDot`, `WallDetectRaycastThrottleSeconds`,
   `WallLeapSpeed`, `WallLeapUpwardSpeed`, `WallLeapNormalWeight`. Starting
   values are placeholders for in-Studio tuning, same as every other
   number in this file — don't spend time guessing "final" numbers here.
2. **Types** — add `wallRunQuery` to `Shared/Types/MovementTypes.luau`'s
   `MovementContext`.
3. **`SpatialQueries.QueryWallRun`** — pure function, side-raycast pair +
   flatness check, per §4.1. Unit-testable in isolation (no character
   state needed beyond a `CFrame` and a `RaycastParams`).
4. **`TraversalMath.WallRunTangentVelocity` / `WallLeapVelocity`** — pure
   functions per §4.2/§4.3, no side effects, no Roblox service calls other
   than vector math.
5. **`MovementStates.luau`** — add `WallRun`, `WallLeap` Symbols.
6. **`StateRules.luau`** — `CanEnter` + topology per §3. Client and server
   both consume this unchanged — do not duplicate the legality logic
   server-side.
7. **`CharacterMover`** — confirm `SetHorizontalVelocity`/
   `SetVerticalVelocity` already exist (they do, from Slide/DoubleJump); if
   either was removed in the §13 revert, restore just those two methods —
   nothing else from the old `CharacterMover` additions (no
   `createOrientationOverride`/`createPositionHold`, those were
   WallClimb-only and stay deferred).
8. **Client states** — `WallRunState.luau` (`Enter`/`Update`/`Exit` per §3),
   `WallLeapState.luau` (one-shot `Enter`, per §3's synchronous-transition
   pattern).
9. **Wire into `AirborneState`/`Movement/init.luau`** — polling
   `RequestTransition(WallRun)` attempt in `AirborneState.Update`; throttled
   `wallRunQuery` probe on the client Heartbeat accumulator; Jump-input
   branch to `WallLeapState` while `fsm.current == WallRun`.
10. **Network** — add `"WallRun"`/`"WallLeap"` to `ClaimableTraversalMove`
    and `DebugMovementState` in `network.zap`; regenerate with
    `zap network.zap`. Mirror the new debug names in
    `Shared/FSM/MovementStateNames.luau`'s `DebugNames`.
11. **Server validation** — `MovementValidationService`: server-side
    `updateWallRunQuery` accumulator, `wallRunEnteredAt` tracking, claim
    branches for both states, force-exit logic in
    `mirrorPassiveTransitions`, `maxSpeedForState` entries. This is the
    step §5 is about — do not ship without it.
12. **Animation slots** — the reverted pass's `WallRunLeft`/`WallRunRight`
    Animation instances are still sitting in
    `Assets/Animations/Movement.model.json` (§13 kept them deliberately).
    Re-wire `LocomotionAnimator`'s `loadTrack` calls for `WallRun`; add a
    one-shot or short loop for `WallLeap` if a clip exists, otherwise leave
    it silent for now rather than reusing an unrelated animation.
13. **Playtest and log real numbers.** Turn on
    `SPEED_SANITY_DEBUG_LOGGING` (already exists in
    `MovementValidationService.luau`) during the first Studio playtest
    pass. Do not hand-tune `WallRunSpeed`/`WallLeapSpeed`/the ray lengths
    from guesses — capture real corrections the way §12's landing-momentum
    grace was measured, and update `docs/MOVEMENT.md` with the results
    (new numbered section, following this file's own pattern) once this
    guide's steps are actually built.

---

## 7. Definition of done

- Wall Run triggers reliably approaching a wall at a shallow/running angle
  (the failure mode that got the last attempt reverted) — verify this
  specifically in Studio before calling the feature working.
- A modified client cannot: claim `WallRun` with no wall present, hold
  `WallRun` past `WallRunMaxDurationSeconds`, or claim `WallLeap` without
  first being validated into `WallRun` server-side.
- `docs/MOVEMENT.md` gets a new numbered section for this build (mirroring
  §9–§13's own format: what shipped, what's still tuning, any bugs found
  and fixed), and this guide's §1 decision table is updated if anything
  changed during the actual build.
- WallClimb/WallLatch remain untouched in `docs/MOVEMENT.md`'s **Deferred**
  section — this pass does not reintroduce them.
