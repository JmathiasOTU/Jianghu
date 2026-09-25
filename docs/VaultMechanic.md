# Vault Mechanic

The reference Vault was built from, and why Jianghu's differs. Part 1 describes how Sorcery's vault works (from the decompiled client). Part 2 lists where Jianghu departs from it. Part 3 records the design goal and the decisions made from it.

Vault shipped on 2026-09-25. How it works now is in [`MovementSystem.md` §4.8](MovementSystem.md#48-vault); keep that current, not this file. The step-by-step build plan this file used to hold is in git history.

---

## Part 1: How Sorcery does it

Source: `Sorcery Decomp/src/ReplicatedStorage/Client/Controllers/MovementController.luau`
- `CheckLedge` (line ~1085): detection
- `PromptVault` (~1152): gating
- `GetYLevel` (~1246): ledge height
- `ClimbVault` (~1264): the motion
- `Update` (~1023) and `Space` (~1113): input buffering

`ClientUtil.GetHealth` is in `Sorcery Decomp/src/ReplicatedStorage/Client/ClientUtil.luau`.

**Trust model:** entirely client-side. The server only receives `ClientEffectDirect:Fire("ClimbVault")` so it can play effects. Nothing is validated.

### 1.1 Detection (`CheckLedge`)

It casts two forward rays from the root part, each 8 studs long along `Root.CFrame.LookVector`, and only hits parts in `workspace.Map`:

```
              clearance ray (+8) ─────────────────────▶   must MISS
                                            ┌──────────── ledge top
   root ●                                   │
          wall ray (−1) ───────────────────▶│ Pos, Norm   must HIT
                                            │
   ◀──────────────── 8 studs ──────────────▶
```

| Check | Rule |
|---|---|
| Wall ray | Origin `Root.Position − (0, 1, 0)`, direction `LookVector × 8`. Must hit. Gives `Wall, Pos, Norm` |
| Clearance ray | Origin `Root.Position + (0, 8, 0)`, same direction. Must **miss**: the wall ends below +8, so there's a top to get over |
| Surface | Rejected if `Norm · Y > 0.25`. Floors and gentle slopes don't count; vertical and overhanging walls do |

There's no facing check beyond "the ray goes where the root faces", and no check that the top of the ledge is standable.

**Vault vs climb.** Sorcery's wall climb (`CheckWall`) uses the same wall ray, but the ray at **+12 must hit** (the wall is tall) and a ray **8 studs straight down must miss** (you're well off the ground). A short wall with open space above is a vault; a tall wall is a climb. On Space, climb is tried first, then vault, then double jump.

### 1.2 Gating and buffering (`PromptVault`, `Update`, `Space`)

| Gate | Value |
|---|---|
| Airborne only | `Humanoid.FloorMaterial == Air` |
| Cooldown | 0.5 s since the last vault (`LastVault`) |
| Action gate | `ActionCheck.DodgeCheck` (stunned, attacking, etc.). Checked again after the wind-up, so being hit mid-vault cancels it |

**Buffer (auto-vault).** Pressing Space in the air, a slide jump and a climb jump all set `Variables.CanVault = tick()`. `Update` then calls `PromptVault()` **every frame for 1 s**. If you reach a ledge within a second of jumping, you vault without pressing again. The buffer is cleared once you've been on the ground for more than 0.25 s since the press.

**Lockouts it creates:**
- A `No Double Jump` tag for 0.25 s.
- `DoubleJump` returns early if a vault happened in the last 0.1 s. This stops the same Space press from triggering both.

### 1.3 Motion (`ClimbVault`)

**Step 0: momentum snapshot** (taken before any movers are cleared):
```
Momentum = Velocity × (0.4, 0, 0.4)       -- keep 40% of horizontal speed
         + (0, |Velocity.Y| / 3, 0)       -- absolute value: a fast fall gives MORE lift
```

**Step 1: wind-up, 0.05 s.**
- `Freeze` + `No Rotate` tags. The Climb animation plays with its speed set to 0, so it holds the first frame.
- A `BodyPosition` (P 25000, D 500, MaxForce 80000) pulls the root toward:
  - **XZ:** `Pos − Norm × 1.25`, 1.25 studs past the wall face, over the top
  - **Y:** `GetYLevel()` (below)
- A `BodyGyro` turns you to face into the wall: `CFrame.lookAt(Root, Root − Norm)`.

`GetYLevel()` estimates the ledge height with two more forward rays (8 studs):
```
Y = Root.Y + 3
if ray at +4 hits: Y = Root.Y + 6
if ray at +6 hits: Y = Root.Y + 8
```
It finds the height in three fixed steps and never looks at where the top surface actually is.

**Step 2: launch, 0.1 s.**
- Re-run the action gate; abort if it fails.
- Snap facing to the camera's horizontal direction: `lookAt(Root, Root + camLook × (1, 0, 1))`.
- A `BodyVelocity` (MaxForce 80000 on every axis) for 0.1 s:
```
V = look × (15 × H) + (0, 35 × H, 0) + Momentum
```
- The Climb animation continues at 1.6× and stops 0.25 s later.
- The FOV jumps by 20 and tweens back to 0 over 0.5 s (Quad).

**`H` (health scaling):** `clamp(Health × 3 / MaxHealth, 0.25, 1)`. Above 33% HP the launch is full; below that it scales down linearly, never under 25%.

### 1.4 All the numbers

| Name | Value | Where |
|---|---|---|
| Ray reach | 8 | wall, clearance, height probes |
| Wall ray height | −1 | relative to the root |
| Clearance ray height | +8 | must miss |
| Max normal up-dot | 0.25 | surface filter |
| Over-the-top inset | 1.25 | `Pos − Norm × 1.25` |
| Height steps | +3 / +6 / +8 | probes at +4 / +6 |
| Cooldown | 0.5 s | `LastVault` |
| Buffer window | 1 s | `CanVault` |
| Buffer clear | grounded > 0.25 s | `Update` |
| No-double-jump tag | 0.25 s | |
| Wind-up | 0.05 s | BodyPosition P 25000 / D 500 |
| Launch hold | 0.1 s | BodyVelocity |
| Forward launch | 15 | × H |
| Upward launch | 35 | × H |
| Horizontal momentum kept | 40% | |
| Vertical momentum kept | abs(vy) / 3 | |
| FOV kick | +20 → 0 over 0.5 s | |
| Climb anim speed | 0, then 1.6 | stops after 0.25 s |

### 1.5 What not to copy as-is

- **`|vy| / 3` has no upper bound.** A long fall into a ledge launches you higher. That's unbounded vertical gain, and our server's ceiling can't allow it. We keep the term but cap it (Part 3).
- **8-stud reach.** The pull can snap you up to 8 studs toward a wall in 0.05 s, which looks like teleporting and is much longer than our cling cast (3 studs).
- **Three-step height guess.** It overshoots low ledges and can put you inside geometry.
- **No standability check.** It will vault onto a sloped roof or a 0.2-stud-thick rail.
- **Deprecated APIs.** `FindPartOnRayWithWhitelist`, `BodyPosition`, `BodyGyro`, `BodyVelocity`.

We copy the camera-steered launch. We don't copy the auto-vault buffer or the health scaling; both were designer decisions (Part 3).

---

## Part 2: How Jianghu differs

How Vault works now is in [`MovementSystem.md` §4.8](MovementSystem.md#48-vault) (the move) and §8.2-§8.4 (server validation). This part lists where it departs from Sorcery; Part 3 gives the reasons.

| | Sorcery | Jianghu |
|---|---|---|
| Trust | Client only; the server plays effects | Claimed (`ClaimTraversalMove "Vault"`), re-probed and bounded by the server |
| Reach | 8 studs | 3 (`VaultReach`) |
| Height window | Wall at root −1, clear at root +8 | Top 1.5 to 6 above the feet |
| Ledge height | Three-step guess (+3 / +6 / +8) | Measured by a downward top probe |
| Standable top | Not checked | Normal Y ≥ 0.7, 1.5 studs deep, 5 studs of headroom (leg footprint) |
| Onto the ledge | 0.05 s `BodyPosition` pull | A mantle of up to 0.2 s (faster if you're rising faster): up the wall face, then across onto the top |
| Launch | `BodyVelocity` held 0.1 s | One-shot velocity writes when the mantle ends; the whole state lasts 0.32 s (the clip's length) |
| Launch direction | Camera | Camera (unchecked by the server; magnitude bounded) |
| Fall-speed lift | abs(vy) / 3, unbounded | abs(vy) / 3, capped at 20 |
| Health scaling | `clamp(3·HP/MaxHP, 0.25, 1)` | None |
| Trigger | Space, plus a 1 s auto-vault buffer | Space; automatic during WallBoost |
| From | Airborne (any state with `FloorMaterial == Air`) | Airborne, DoubleJump, WallCling, WallBoost; not WallRun |
| Vault vs climb | Climb first, then vault | Vault first, then cling |
| Double jump after | Blocked 0.25 s | Blocked 0.25 s; not spent |
| FOV | +20 kick, tweened back over 0.5 s | +10 kick eased back over 0.5 s, on top of the take-off FOV (`FOVKick` cue) |

---

## Part 3: Decisions

### Design goal

Vault is a **mantle assist**, not a climb. If you're almost over an edge but not quite (your jump came up a little short and the lip is around your chest or head), the vault puts you on top. It is not for scaling tall walls from a distance; WallCling and WallBoost do that. Every decision below follows from this.

### Decided by the designer (2026-09-25)

| Topic | Decision | Consequence |
|---|---|---|
| Launch direction | **Camera-steered**, as in Sorcery | Read at launch. The server bounds the magnitude only |
| Auto-vault buffer | **No buffer.** Space in the air or while clinging; **automatic during WallBoost** (revised later on 2026-09-25) | The designer wants cling → boost → carried over the lip as one sequence. Automatic stays scoped to the boost: from Airborne/DoubleJump it would snap you onto every low box you jump beside. Sorcery's 1 s post-press buffer isn't copied |
| Fall-speed bonus | **Keep abs(vy) / 3, capped** at `VaultMaxMomentumUpward` | Gives `VaultMaxRise` a finite bound |
| Health scaling | **No, deferred** | `Humanoid.Health` is a fixed rig-compatibility shell (`ARCHITECTURE.md` §12) and no real HP system exists yet. Revisit once real HP, or a Qinggong resource, exists |
| Getting onto the ledge | **Keep the 1.5-6 window.** First a one-frame snap covered by the animation; **revised the same day to a 0.2 s mantle** after a playtest ("you just snap") | The lip is meant to be at chest or head height, so the window stays. Lifting up to 6 studs in one frame read as a teleport no matter the animation |

### Decided from the goal (2026-09-25)

| Topic | Decision | Why |
|---|---|---|
| Reach | **3 studs** (Sorcery: 8) | "Almost over" means you're already at the wall. Matches `WallClingDistance`. The mantle moves you at most reach + inset (4.25 studs) sideways |
| Height window | Ledge top **1.5 to 6 studs above the feet** (knee to just above the head) | Below knee height you clear it or step up anyway; above head height you're not almost over, so it's a cling |
| Ledge height | **Measured** with a downward top probe | The feet land exactly on the top; no overshoot or clipping |
| Standable top | **Required:** top normal Y ≥ 0.7, 1.5 studs of depth, 5 studs of headroom | The assist should only fire where you can actually stand. No vaulting onto rails, steep roofs or under ceilings |
| Vault vs WallCling | **Vault first** when a standable top is in the window, cling otherwise | They separate cleanly on the clearance cast |
| From DoubleJump | **Allowed** | Double jumping toward a ledge and coming up short is the main use case |
| From WallCling | **Allowed, on Space** (Space did nothing while clinging) | Hanging just under a lip and pressing Space to pull up is the same "almost over" case |
| From WallBoost | **Allowed, automatically** (Space works too) | A boost that runs up past the lip is exactly the case Vault exists for. How high it still reaches, before the boost's separation push carries you out of the 3-stud reach, needs a playtest |
| From WallRun | **Not allowed** | Wall runs are along side walls; a ledge ahead is a different wall. Leap off, then vault from Airborne |
| Spends the double jump? | **No**, matching WallCling. Keeps Sorcery's 0.25 s double-jump block | A vault is recovery, not an extra jump; the block stops a quick second press from double jumping over the launch |
| Launch strength | **Sorcery's 15 forward / 35 up** as starting points; fall-speed lift capped at 20 | 35 up is about 3 studs of rise: enough to clear the lip, not to gain real height. 35 + 20 = 55, the same as a jump |

### Decided while building (2026-09-25)

Found by checking the plan against the code, before and during implementation.

| Topic | Decision | Why |
|---|---|---|
| Wind-up | **None:** the mantle is the travel time, and the launch fires the moment it ends | Sorcery's 0.05 s only existed as travel time for its `BodyPosition`. A pause on the ledge would make `Update`'s grounded check resolve a landing before the launch fired |
| Mantle motion | **Up the wall face, then across, at one constant speed; each frame aims for where the path will be at the end of that frame** (`TraversalMath.VaultMantlePoint`). **At most 0.2 s, less when already rising faster** (`VaultMantleDuration`), so a fast boost carries over the lip at its own speed rather than braking to about 55 st/s | First built as a one-time `PivotTo` snap, which a playtest found too abrupt. Tracking a timed path arrives exactly on time; a velocity recomputed every tick as (target − position) / T would be exponential decay and never arrive (about 63% at T). Rising before crossing keeps the body off the lip's corner |
| Mantle clearance | **Feet 0.5 above the top** before crossing | Clears the lip, and keeps the Humanoid from reading the top as floor mid-mantle |
| Leaving Vault | **Always to Airborne at the end of the window; no landing checks before it; never into Run/Sprint** (no topology edges, `preAirborneLocomotion` cleared on entry, landings resolved without resume) | Playtest: a landing read in the frame of the launch (still taken from before it) resolved to a resumed Run, and a double-tap W could start Run mid-vault; the Run animation broke the flow. A vault is a recovery; you come out walking |
| Launch shape | **One-shot velocity writes** | A constraint followed by a synchronous hand-off would be cleared by `Exit` before physics integrates it, the trap `WallLeapState` documents |
| Server rise bound | **`VaultMaxRise` = `VaultMaxLedgeHeight` + `VaultMantleClearance` + ballistic rise at the momentum cap**, apex one mantle later | The mantle lifts you before the launch; leaving it out would correct most vaults onto 3-6 stud ledges |
| Anchor on the ledge | **For one claim lag plus one mantle after an accept, a ground anchor allows the vault's launch speed** | The mantle ends with the feet over ground the support probe sees, which re-anchors the ceiling to "here plus one jump" and would drop the accept's raise |
| Server ledge probe | **Current root, then the root history over one claim lag** | The mantle moves the replicated root onto the ledge, where no wall is in front of it. Probing where the root was a moment earlier finds the ledge again; each candidate is a real position and runs the full probe. The facing check reads the probe's own cast direction for the same reason |
| Probe cadence | **Server: claim time and buffered retries only.** Client: on the press, and during WallBoost on a throttle derived from the rise speed (`VaultAutoProbeInterval`) | A vault has no sustain check, so the server never needs to poll. A boost at 120 st/s crosses the 4.5-stud window in about 0.04 s, so a fixed 0.1 s throttle would miss it |
| Horizontal bound | **15 + 40% of the server's cap before the vault**, raising the airborne allowance only if that exceeds the cap | Tighter than assuming the WallLeap allowance; never binds at shipped tuning |
| Mantle and the speed check | **An exact displacement credit** of reach + inset, for windows starting within one claim lag plus one mantle of the accept | The leg across is faster than the cap for a short mantle. From a cling (cap 0) the window's budget can't absorb it |
| Cooldown clock | **Server accept time, backdated by time buffered** | Same as the cling clock; brings the server's cooldown clock as close to the client's as it can see |
| Headroom | **The leg footprint swept up**, not one ray | A single ray passes beside a pillar the body would overlap |
| Depth tolerance | **Named constant** `VaultTopDepthTolerance` | `ARCHITECTURE.md` §2: no magic numbers |
| FOV kick | **+10 over 0.5 s**, a new one-shot `FOVKick` cue field added on top of the held take-off FOV (`MOVEMENT_POLISH_ARCHITECTURE.md` §4.2) | A `TargetFOV` on Vault would have stayed raised through Airborne (`HoldsFOV`) until landing. Smaller than Sorcery's +20 because sprint and wall-run FOV are already raised |
