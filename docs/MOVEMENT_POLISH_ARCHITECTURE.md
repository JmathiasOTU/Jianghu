# Movement Polish Architecture: VFX, SFX, Camera, FOV and Shift Lock

How movement gets its juice: sounds, particles, camera FOV, camera shake and a smooth shift lock. This is purely visual and kept separate from [`MovementSystem.md`](MovementSystem.md), which covers how movement *behaves*. The project-wide rules are in [`ARCHITECTURE.md`](ARCHITECTURE.md), cited as `ARCHITECTURE §N`.

**Keep it current.** When a polish decision or module changes, update the section here in the same change.

**Status:** code complete. Footsteps have their sound pack; the other cues have no sounds or particles yet. Nothing has been playtested (§9).

---

## 0. Decisions

| Question | Decision |
|---|---|
| Can polish affect gameplay (speed, hitboxes, legality)? | **No.** It only reads the movement FSM and never writes to it, `CanEnter` or physics. Anything that affects gameplay (for example a slow-motion parry effect) is a combat decision, routed through `CombatConstants`. |
| How does a state get its polish? | One data table, `Shared/Presentation/MovementCues.luau`, maps each `MovementState` to its cues. The controllers walk that table generically. **A new state's polish is a new table row, not new code** (§1). |
| Where do the instances come from? | Authored in Studio as one R6 rig template (`Assets/FX/Movement`), which the server mounts onto every character. Nothing rig-attached is built with `Instance.new` (same spirit as ARCHITECTURE §8) (§2). |
| Replication | Each row declares `Replication: "Local" \| "Nearby"`. `"Local"` never leaves the mover's client. `"Nearby"` one-shots are **sent by the server**, driven by its own mirrored FSM, to everyone except the mover. There's no client→server cue request (§5). |
| Shift lock | **Our own implementation**, adapted from the designer's reference code, replacing Roblox's default mouse lock (§4.3). |
| Smoothing | A small in-repo damped spring, `Shared/Util/Spring.luau`, not a Wally dependency. It's a spring rather than `TweenService` so a goal that changes mid-blend (Sprint → Slide → Sprint in under a second) carries its velocity instead of popping (§4.1). |
| Footsteps | Driven by distance travelled, not by state entry. The cue table supplies the sound and stride per state (§3.2). |
| Live-tunable in the F4 overlay? | **No.** That pipeline exists for exploit-relevant physics numbers the server validates (MovementSystem §10). Polish numbers live in `PresentationConstants.luau` and are retuned by editing it. |
| Who sees what | The mover sees and hears every cue. Bystanders get only `"Nearby"` one-shots. Loops, FOV, FOV kicks and camera shake are never replicated. |

---

## 1. The cue table

`Shared/Presentation/MovementCues.luau` is the only place that says which state plays what:

```luau
export type MovementCueDefinition = {
	-- SFX
	EnterSound: string?, -- one-shot on entry
	LoopSound: string?, -- plays while this is the current state
	FootstepSound: string?, -- set name; plays <set><FloorMaterial> every FootstepStrideStuds
	FootstepStrideStuds: number?,

	-- VFX
	EnterParticle: string?, -- :Emit(EnterParticleCount) on entry
	EnterParticleCount: number?, -- nil = PresentationConstants.DefaultEmitCount
	LoopParticle: string?, -- Enabled while this is the current state

	-- Camera
	TargetFOV: number?, -- FOV spring goal while current; nil = BaseFOV unless HoldsFOV
	HoldsFOV: boolean?, -- keep the previous goal (mid-air states)
	CameraShake: string?, -- PresentationConstants.ShakeProfiles key, on entry
	FOVKick: string?, -- PresentationConstants.FOVKickProfiles key, on entry

	Replication: ("Local" | "Nearby")?, -- nil = "Local"
}
```

A state with no row is silent, with base FOV and no shake. Every controller treats that as the correct default, so rows only exist for states that want polish.

**Mid-air FOV.** Airborne, DoubleJump, SlideJump, WallLeap and Vault set `HoldsFOV`. Without it, every sprint jump would dip FOV back to base mid-air and pump it up again on landing. With it, a jump keeps the FOV it took off with, and a leap off a wall run keeps the wall run's FOV until landing.

**Adding polish to a state:** add or extend its row, and author any new named `Sound`/`ParticleEmitter` in the rig template (§2). No controller changes. `tests/specs/MovementCues.spec.luau` checks every row (fields, strides, FOV range, shake profile names, replication values).

### Reading the table: one-shots vs. sustained cues

`fsm.changed` is **not** a reliable signal for "what state are we in now". SlideJump and WallLeap hand off to Airborne from inside their own `Enter`, so the change fires again while the first change is still being handled. LemonSignal calls the newest connection first, so a handler connected before Movement's main handler receives `(Airborne, WallLeap)` *before* `(WallLeap, WallRun)`. Reading the latest `next` would then leave it on a stale state (the same class of bug as audit M-019). So:

- **One-shots** (`EnterSound`, `EnterParticle`, `CameraShake`) fire from `fsm.changed` on `next`. Order doesn't matter: each event really did enter that state.
- **Sustained cues** (`LoopSound`, `LoopParticle`, `TargetFOV`) are matched to `fsm.current` every frame: if the wanted loop differs from the active one, stop one and start the other. This is idempotent, and it's how `LocomotionAnimator` already picks its clip.

### Debounce

One-shots skip a replay of the same cue name within `PresentationConstants.MinCueRetriggerSeconds` (`Shared/Presentation/CueDebounce.luau`, used by the SFX, VFX and camera controllers and, per player, by the server's Nearby broadcast). None of today's one-shot states can oscillate (HardLanding needs a 120-stud fall and locks for 1.11 s; WallLeap needs a WallRun first), so this is only a cheap guard against future rows.

---

## 2. Instances: one R6 rig template, mounted by the server

The template syncs to `ReplicatedStorage.Assets.FX.Movement` and mirrors the R6 rig: a folder per body part, holding a folder per existing attachment, holding that attachment's effects:

```
Movement/
    HumanoidRootPart/
        RootAttachment/        HardLandingThud, WallLeapBurst, SlideScrape, WallRunWind, VaultWhoosh (Sounds)
                               HardLandingDust, WallLeapBurst, WallRunTrail, VaultDust (ParticleEmitters)
    Left Leg/
        LeftFootAttachment/    Footstep/ (pack: Plastic, Grass, Metal, Wood, Concrete, Fabric, Sand, Glass)
                               SlideDust (ParticleEmitter)
    Right Leg/
        RightFootAttachment/   Footstep/ (same pack file, mapped again)
                               SlideDust (ParticleEmitter)
```

**Authoring.** The template's folders (part → attachment) are declared in `default.project.json`; effects are added as files saved from Studio and mapped into those folders:

1. Build or collect the effects in Studio **outside** the Rojo-synced tree (e.g. in Workspace).
2. Right-click → *Save to File* into `Assets/FX/` as `.rbxmx`. Sounds alone are simpler as a hand-written `.model.json` (`Assets/FX/Footsteps.model.json` is one; note Rojo 7.7 reads attributes from a lowercase `attributes` key).
3. Map the file into the right attachment folder in `default.project.json`. The project key becomes the instance's name.

A file can hold a single effect or a **pack**: any container of effects (a Folder, or the `SoundGroup` a toolbox pack ships in). The mount flattens a pack onto the attachment, naming each effect `<pack name><effect name>` (a pack `Footstep` holding `Concrete` mounts as `FootstepConcrete`), because a Sound only plays positionally directly under a part or attachment. Set a `SoundGroup` string attribute (`Footsteps`, `Loops` or `Impacts`) on each Sound, or once on a pack's folder for all its sounds. Emitters can be saved enabled or disabled; the mount turns them off.

Only default R6 attachments are used: `RootAttachment` (HumanoidRootPart), `LeftFootAttachment`/`RightFootAttachment` (legs), `LeftGripAttachment`/`RightGripAttachment` (arms), plus the Torso and Head ones if a cue ever needs them. The same name may appear under several attachments (both feet); a cue then drives every instance with that name.

**Mounting.** `Server/Services/MovementCueService.luau` clones the template onto each character on `CharacterAdded`, moving each attachment folder's children onto the rig's matching attachment. It warns if an attachment is missing, and marks the character so it never mounts twice. Mounting on the server means the instances replicate, so a bystander's client can play a `"Nearby"` cue on someone else's character. A client-side clone would exist only on the mover's client.

- **Sound groups:** `SoundGroup`s live in `SoundService` (declared in `default.project.json`). A Rojo model file can't reference instances outside itself, so each `Sound` names its group in a `SoundGroup` string attribute and the mount assigns it (warning if the group doesn't exist). A future volume slider is then one `SoundGroup.Volume` write.
- **Roll-off:** every sound is parented under a part/attachment, so it's positional. The mount sets `RollOffMode = InverseTapered` and `RollOffMaxDistance = PresentationConstants.NearbyRollOffMaxDistance` on sounds used by `"Nearby"` rows, so engine falloff does the distance culling (Roblox's default max distance is effectively map-wide).

**Finding instances on the client.** `CharacterFX` is a small per-character index mapping cue name → instances. It only indexes instances the mount tagged with the `MovementCue` attribute, so the character's other sounds are never picked up. It's built from the character's descendants and kept current with `DescendantAdded`/`DescendantRemoving`, so it doesn't matter whether the mount replicates before or after the client starts listening. A name that isn't there yet is skipped silently, just as `LocomotionAnimator` skips a blank `AnimationId`.

**Preload.** `ContentProvider:PreloadAsync` runs once per client session on the template, in a spawned thread from `MovementController.Init`, so a cue's first play doesn't hitch while its content loads. It isn't repeated each life; the content never changes.

---

## 3. SFX and VFX controllers

`Client/Controllers/Movement/Presentation/SFXController.luau` and `VFXController.luau` sit next to `FacingController`/`LocomotionAnimator` and follow the same pattern: built per life in `Movement/init.luau`'s `setupCharacter`, own a `Trove`, read the FSM and never write it. Each is a small, direct module. The shared thing is the data (`MovementCues`), not a base class.

### 3.1 Shape

- **On `fsm.changed(next)`:** play `next`'s one-shot (`EnterSound` / `EnterParticle`), debounced (§1).
- **Every frame:** match loops to `fsm.current` (§1).
- **SFX only:** footsteps (§3.2), with `PresentationConstants.FootstepPitchJitter` so repeats don't sound identical.

### 3.2 Footsteps

```luau
-- every Heartbeat
local cue = MovementCues[fsm.current]
if not (cue and cue.FootstepSound and characterMover:IsGrounded()) then
	strideAccumulated = 0
	return
end
strideAccumulated += characterMover:GetHorizontalVelocity().Magnitude * dt
if strideAccumulated >= cue.FootstepStrideStuds then
	strideAccumulated = 0
	-- alternate the LeftFootAttachment / RightFootAttachment instance
end
```

**Materials.** Each step plays `<FootstepSound><Humanoid.FloorMaterial>` (`FootstepConcrete`, `FootstepGrass`, ...). For a material the pack has no sound for, it tries that material's alias (`PresentationConstants.FootstepMaterialAliases`, e.g. terrain `Mud` → `Grass`), then `FootstepDefaultMaterial` (`Plastic`), then a plain `<FootstepSound>`. `tests/specs/FootstepPack.spec.luau` loads the pack file and checks that its sound names are real materials, that every alias and the default point at a sound it has, and that its `SoundGroup` exists. Walk, CrouchWalk, Run and Sprint all use the one `Footstep` pack: eight single-step clips, one per surface category, carried over from the designer's previous game along with its material map. The pack is mounted on both feet so consecutive steps alternate instances and each clip has two strides to finish. A separate sprint set would be a second pack and a different row value. Footstep sounds are forced to `Looped = false`, since some packs ship looping sounds.

**Roblox's default footsteps.** `RbxCharacterSounds` gives every character a looping `Running` sound on its root part. `SFXController` mutes it (`Volume = 0`) on the local character only. That script's other sounds (jump, land, swim, climb) are kept, and other players' default running sounds still play.

Distance-based, so cadence scales with real speed without a per-tier timer. The accumulator is also reset on every state change, so switching from Sprint's longer stride to Walk's shorter one doesn't fire an early step. Alternating feet also means one `Sound` isn't restarted every step, which would cut off its tail at sprint cadence (about 6 steps/s).

---

## 4. CameraController

`Client/Controllers/CameraController.luau`, a **flat** module directly under `Controllers/` so `Loader.LoadChildren` loads it (a module inside a plain subfolder is never loaded; MovementSystem Appendix B). Unlike the per-life controllers, it lives for the whole session, so its springs keep their motion across respawns instead of snapping FOV back to base.

### 4.0 Following the current life

The camera can't capture one `fsm`/`Humanoid`: `Movement/init.luau` builds a new `StateMachine` every life. It also can't be handed them by Movement directly (ARCHITECTURE §2: controllers don't reach into each other). Instead a small client module, `Client/State/MovementLife.luau`, publishes the current life:

```luau
MovementLife.Set(life)        -- Movement/init.luau, once per life
MovementLife.Current(): Life? -- whoever needs it now
MovementLife.Started          -- LemonSignal<Life>
-- Life = { humanoid, rootPart, fsm, trove }
```

`Current()` exists because `Loader.SpawnAll` starts every `Init` at the same time, so Movement's first life can begin before the camera subscribes. The camera handles `Current()` once and then `Started`, and connects its per-life listeners to `life.trove`, so they're torn down with that life.

### 4.1 `Shared/Util/Spring.luau`

A damped harmonic spring with a closed-form (exact) step, so it's frame-rate independent: one 1/30 s step lands in exactly the same place as two 1/60 s steps.

```luau
Spring.number(dampingRatio, frequencyHz, initial: number): Spring<number>
Spring.vector3(dampingRatio, frequencyHz, initial: Vector3): Spring<Vector3>
spring:SetGoal(goal)
spring:Update(dt) -> position
spring:Reset(position) -- jump there at rest
```

Both constructors share one implementation (numbers and `Vector3`s support the same arithmetic). The typed constructors give each caller a concrete type, since Luau can't constrain a generic to "supports `+` and `*`". Each step costs a few `exp`/`sin`/`cos` calls; with two springs per frame, nothing is cached. It's pure math and covered by `tests/specs/Spring.spec.luau`.

### 4.2 FOV and shake

- **FOV:** every frame, the goal is the current row's `TargetFOV`, else unchanged if it `HoldsFOV`, else `BaseFOV`, and the spring's value is written to `Camera.FieldOfView`. The default camera scripts never touch FOV.
- **FOV kick:** an `FOVKick` cue (fired from `fsm.changed`, debounced) adds `PresentationConstants.FOVKickProfiles[name].Amount` degrees at once, easing back to zero over its duration with the square of the time left (Sorcery's Quad tween). It's added to the spring's output, not pushed into its goal, so the state's own FOV underneath is untouched and the kick can't fight a `HoldsFOV`. Vault uses it (+10 over 0.5 s; Sorcery's is +20, but ours starts from an already raised sprint or wall-run FOV).
- **Shake:** a `CameraShake` cue (fired from `fsm.changed`, debounced) starts a short random offset from `PresentationConstants.ShakeProfiles[name]` that decays with the square of the time left. It's a pure translation in camera space, so it doesn't need undoing: the default camera script rebuilds its position from the focus every frame and reads only the camera's *direction*, which a translation doesn't change. A rotating shake would drift the camera and would need undoing before the camera script's next update.
- Shake is a decaying random impulse, not a goal-seeking spring, so it isn't built on `Spring`.
- FOV, shift-lock offset and shake all run in one render step at `RenderPriority.Camera + 1`, right after the default camera script.

### 4.3 Shift lock (our own)

Adapted from the designer's reference implementation. Roblox's default mouse lock is off (`StarterPlayer.EnableMouseLockOption = false` in `default.project.json`): it applies its shoulder offset inside the camera module in a single frame, so a spring layered on top would stack two offsets.

- **Toggle:** Left/Right Shift (ignoring input the game already handled), only while a life exists. The life ending (death, respawn) unlocks.
- **Locked:** `MouseBehavior = LockCenter`, re-asserted every frame because the default camera script can release it. `FacingController` and the camera-lock level claim (`not Humanoid.AutoRotate`, MovementSystem §7) key off it, so facing and server validation work unchanged. The mouse icon switches to `ShiftLockMouseIcon`.
- **Shoulder offset:** `ShiftLockOffset` (1, 0.25, 0; pulled in from the reference's 1.75, which read as too far right), eased in and out by `Spring.vector3` with the reference's damping (0.7) and in/out speeds, and applied as a camera-space translation (§4.2). It isn't a root-relative `Humanoid.CameraOffset`, which would swing sideways while WallRun locks facing to the wall tangent. Nothing writes `Humanoid.CameraOffset`.
- **First person:** no shoulder offset once the head's `LocalTransparencyModifier` passes `FirstPersonHeadTransparency` or the camera is within `FirstPersonHeadDistance` of it.
- **Not ported from the reference:** its character rotation (facing belongs to `FacingController`; two writers would fight), and its BindableEvent config/toggle hooks (constants live in `PresentationConstants`; add an external toggle when something needs one).

## 5. Replication: server-sent "Nearby" cues

```
server mirror FSM changes state (MovementValidationService, createSession's fsm.changed)
  → Server/Events/MirrorStateChanged:Fire(player, next, previous)
  → MovementCueService: MovementCues[next].Replication == "Nearby"?
  → Network.PlayMovementCue.FireExcept(player, { player = player, state = name })
  → other clients: NearbyCuePlayer plays that row's EnterSound + EnterParticle on player.Character
```

```zap
event PlayMovementCue = {
	from: Server,
	type: Unreliable,
	call: SingleSync,
	data: struct {
		player: Instance.Player,
		state: MovementStateName, -- every state by name; shared with the debug overlay
	},
}
```

- **Server-driven:** the server's own mirror decides HardLanding (from its fall height), WallLeap and Vault (on an accepted claim), so bystanders only see moves the server accepted. There's no client request to validate or rate-limit, and no second cue enum to keep in step with the table: the server filters with the same `MovementCues` rows.
- **The payload is the state, not a cue name.** The receiver plays that row's `EnterSound` and `EnterParticle`. It never plays `CameraShake` or `FOVKick`: another player's landing doesn't move your camera.
- **Excluding the mover:** `FireExcept(player, ...)`, because the mover already played the cue locally. As a backstop, the receiver also ignores events about `Players.LocalPlayer`.
- **Receiver** (`Movement/Presentation/NearbyCuePlayer.luau`, callback set once in `MovementController.Init`, so it works while the local player is dead): skips silently if `player.Character` hasn't streamed in (ARCHITECTURE §14) or the named instance isn't there, and skips rows that aren't `"Nearby"`. It finds the instances with `CharacterFX.Scan`, a one-off lookup using the same `MovementCue` tag rule as the per-life index; cues are rare enough that no live index per remote character is needed.
- **Enum parity:** `tests/specs/MovementStateNames.spec.luau` checks that network.zap's `MovementStateName` enum and `Shared/FSM/MovementStateNames.luau` list the same states.
- **Server guard:** a per-player `MinCueRetriggerSeconds` floor on the same state, matching the client's debounce.
- `Unreliable`: a dropped landing thud is invisible.
- **No distance culling on the server**: engine roll-off (§2) handles distance. Add interest management only if a measured bandwidth number calls for it (ARCHITECTURE §9's "don't pad for a cost you haven't measured" spirit).

---

## 6. Constants

`Shared/Constants/PresentationConstants.luau`, one file (like `MovementConstants`), `--!strict`, every polish number (ARCHITECTURE §2). Not in the F4 tuning enum (§0).

| Group | Holds |
|---|---|
| Cues | `MinCueRetriggerSeconds`, `DefaultEmitCount`, the `CueAttribute`/`SoundGroupAttribute`/`MountedAttribute` names shared by the mount and the index |
| SFX | `FootstepPitchJitter`, `NearbyRollOffMaxDistance` |
| Camera | `BaseFOV`, `FOVDampingRatio`, `FOVFrequency`, `ShakeProfiles: { [string]: { Magnitude, DurationSeconds } }`, `FOVKickProfiles: { [string]: { Amount, DurationSeconds } }` |
| Shift lock | `ShiftLockOffset`, `ShiftLockDampingRatio`, `ShiftLockIn/OutFrequency`, `ShiftLockMouseIcon`, `FirstPersonHeadTransparency`, `FirstPersonHeadDistance` |

All values are starting points, not tuned. Retune from playtests.

---

## 7. Module map

```
src/Shared/Presentation/MovementCues.luau                          the cue table
src/Shared/Presentation/CueDebounce.luau                           one-shot retrigger floor
src/Shared/Constants/PresentationConstants.luau                    every polish number
src/Shared/Util/Spring.luau                                        damped spring

src/Client/State/MovementLife.luau                                 current life, for CameraController
src/Client/Controllers/CameraController.luau                       FOV, shake, shift lock
src/Client/Controllers/Movement/Presentation/SFXController.luau    per life
src/Client/Controllers/Movement/Presentation/VFXController.luau    per life
src/Client/Controllers/Movement/Presentation/CharacterFX.luau      cue name → instances index (§2)
src/Client/Controllers/Movement/Presentation/NearbyCuePlayer.luau  plays other players' Nearby cues (§5)

src/Server/Services/MovementCueService.luau                        mount FX, broadcast Nearby cues
src/Server/Events/MirrorStateChanged.luau                          server mirror state changes

default.project.json → ReplicatedStorage.Assets.FX.Movement       R6 FX template folders
Assets/FX/*.rbxmx, *.model.json                                    effects and packs (Footsteps.model.json today)

tests/specs/Spring.spec.luau
tests/specs/MovementCues.spec.luau
tests/specs/CueDebounce.spec.luau
tests/specs/MovementStateNames.spec.luau
tests/specs/FootstepPack.spec.luau
```

Changes to existing files:
- `Movement/init.luau`: construct `CharacterFX`/`SFXController`/`VFXController` next to `LocomotionAnimator`; `MovementLife.Set(...)` once per life; in `Init`, the once-per-session preload and the `PlayMovementCue` callback.
- `MovementValidationService`: fire `MirrorStateChanged` from `createSession`'s `fsm.changed` handler.
- `network.zap`: `DebugMovementState` renamed to `MovementStateName` (and its one use in `DebugOverlayController`), `PlayMovementCue` added.
- `default.project.json`: `ReplicatedStorage.Assets.FX.Movement`, `SoundService` sound groups (`Footsteps`, `Loops`, `Impacts`).
- `default.project.json`: `StarterPlayer.EnableMouseLockOption = false` (§4.3).

Not built until a real caller needs it: a pool for effects that aren't attached to a rig (combat clash sparks, projectile impacts at world points). When one arrives: a fixed ring of pre-created, disabled instances, acquired and released, never created/destroyed per effect (ARCHITECTURE §6).

---

## 8. Open questions

- Exact FOV, shake and stride numbers: starting points, tune in playtests.
- **Other players' footsteps** still come from Roblox's default `Running` loop (§3.2). Replacing them with ours is the "other players' footsteps" question below.
- **Camera clipping with shift lock:** the shoulder offset is applied after Roblox's occlusion handling (Poppercam), so against a wall the offset camera can clip into it. The reference behaves the same way. If it shows up in playtests, cast from the focus to the offset position and shorten the offset.
- **Smooth facing in shift lock:** the reference turns the character toward the camera gradually; `FacingController` snaps. Adding it would be a `FacingController` change, and the server's backpedal check compares facing to movement (MovementSystem §8.1), so a lagging turn would need checking against it first.
- Cue rows for `WallCling`, `WallBoost`, `DoubleJump`, `SlideJump`, `Airborne`: empty until someone wants them.
- **Vault sounds and particles:** its row names `VaultWhoosh` and `VaultDust` (played locally and to Nearby players), not authored yet, like the other impact cues. Build them into `RootAttachment` in the template (§2). A light `CameraShake` on the vault is one more row field if the kick alone feels flat.
- Other players' footsteps (useful for positional awareness). They could be derived on each client from replicated velocity with no network cost; decide separately.
- A volume slider (the `SoundGroup`s are ready) and an effects-quality or reduced-motion setting (skip loop particles, zero shake). Both are new product scope; controllers already gate on the cue table, so each is one more check at the same points. Needs a persisted preference (ProfileStore, ARCHITECTURE §13).
- As more effect files land, extend `FootstepPack.spec.luau`'s approach into a spec checking that every name in `MovementCues` is mounted somewhere in the template.

---

## 9. Build order

1. **Pure modules**: `Spring` + spec, `PresentationConstants`, `MovementCues` + spec. *Done.*
2. **CameraController**: `MovementLife`, FOV spring, shake, shift lock. *Built; needs a Studio playtest.*
3. **FX template and local cues**: template folders, the server mount (with packs), `CharacterFX`, `SFXController` (material footsteps), `VFXController`, preload. *Built. Footsteps have their pack (`Assets/FX/Footsteps.model.json`, eight single-step clips, on both feet).*
4. **"Nearby" replication**: `MirrorStateChanged`, `PlayMovementCue`, the receiver. *Built; needs a two-player Studio test once the impact sounds/particles exist.*
