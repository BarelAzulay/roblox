# Nimbus Climb — architecture & module contracts

A co-op cloud-parkour hobby game for Roblox. Players hang out in a pretty cloud-village **lobby**,
walk into a **match portal** to form a party (1–4 players), and are sent to a procedurally generated
**sky parkour course** (built in the same server, far away). Teams climb stage by stage, share
checkpoints, revive each other, dodge hazards, and collect floating **cloud tokens**.

This document is the contract. Every module must implement exactly the API below so modules written
independently still fit together. If you need something not listed, add it to YOUR module only and
keep the listed API intact.

## Hard language rules (all Lua files)

* Plain **Lua 5.1-compatible syntax** (Roblox executes Luau, but our tooling parses stock Lua):
  NO type annotations, NO `continue`, NO `+=`/`-=`, NO `if a then b else c` expressions,
  NO backtick strings, NO `//`. Use `goto`-free loops; emulate continue with `if not x then ... end`.
* Roblox globals are fine (`game`, `workspace`, `Instance`, `Vector3`, `CFrame`, `Color3`, `UDim2`,
  `Enum`, `task`, `Random`, `TweenInfo`, `Ray`, `RaycastParams`, `OverlapParams`, `os`, `math`, ...).
* Use `task.wait/spawn/delay/defer`, never `wait/spawn/delay`.
* Use `Humanoid.UseJumpPower = true` + `JumpPower`.
* Every module is a ModuleScript returning one table. Only `*.server.lua` / `*.client.lua` files
  are scripts.
* No external asset ids (no meshes, decals, sounds from the toolbox). Everything is built from
  Parts + built-in particle textures `rbxasset://textures/particles/sparkles_main.dds`,
  `rbxasset://textures/particles/smoke_main.dds`, `rbxasset://textures/particles/fire_main.dds`.
* Fonts: ALWAYS through `Theme` (`Theme.Label`, `Theme.Style`, `Theme.Fonts.<Role>`) — never a raw
  `Enum.Font`. Every piece of text (HUD, billboards, signs, toasts) must be styled via Theme.
* Server is authoritative for health, damage, tokens, checkpoints, match flow. Clients only do
  input, movement feel, and UI.
* Every long-lived loop must be stoppable (match end destroys everything it created).
* Be defensive: `pcall` DataStore calls; guard `nil` characters/humanoids; players can leave anytime.

## Layout

```
src/shared/   -> ReplicatedStorage.Shared      Config Theme Util Remotes   (DONE, read them)
src/server/   -> ServerScriptService.Server    Main.server.lua + Services/*.lua
src/client/   -> StarterPlayerScripts.Client   Main.client.lua + Controllers/*.lua
```

Require paths:
* Server service requiring a sibling: `require(script.Parent.OtherService)`
* Server/Client requiring shared: `local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")`
  then `require(Shared.Config)`.
* Client controller requiring a sibling: `require(script.Parent.OtherController)`.

## Shared conventions

* **Tags** (`Config.Tags.*`) mark parts so services can find behaviours. **Attributes** carry
  parameters. Course parts are tagged by CourseBuilder and animated/handled by HazardService /
  MatchService.
* Player attributes (`Config.Attr.*`): `CloudTokens` (lifetime, persisted), `MatchTokens`,
  `InMatch`, `Downed`, `Stamina` (client writes).
* Remotes are in `Config.Remotes`; payload shapes are defined below.
* The lobby sits at `Config.Lobby.Origin` (y=300). Matches are built at
  `Config.Match.ArenaOrigin + Vector3.new((slot-1) * Config.Match.SlotSpacing, 0, 0)`.
* Course direction: starts at its origin, progresses toward **+Z**, climbing. Never goes lower than
  `origin.Y - 10`. Kill plane = `origin.Y - 60`.
* Difficulty ids: `"Breeze" | "Gale" | "Thunderstorm"`.

---

## Server modules (`src/server/Services/`)

### LightingService  — `LightingService.lua`
Owns sky, atmosphere and global workspace settings.
```lua
LightingService.Init()
```
Sets: Lighting (ClockTime ~ 17.5 golden hour, soft pink/blue ambient), `Atmosphere`, `Sky` (no asset
ids: leave default sky, tweak star count/celestial bodies), `Bloom`, `SunRays`,
`ColorCorrection`, `DepthOfField` (subtle). `workspace.Gravity = Config.Physics.Gravity`,
`workspace.FallenPartsDestroyHeight = -2000`, `Players.CharacterAutoLoads = true`,
`workspace.StreamingEnabled` is left false. Idempotent.

### LobbyBuilder — `LobbyBuilder.lua`
Builds the cloud village **procedurally** at `Config.Lobby.Origin`.
```lua
LobbyBuilder.Build() -> LobbyInfo
LobbyInfo = {
  Folder = Folder,                 -- parent of everything, workspace.NimbusLobby
  SpawnCFrame = CFrame,            -- where players appear (plaza centre, +3 studs up, facing a portal)
  Portals = {                      -- keyed by difficulty id, ALL three present
    Breeze = PortalInfo, Gale = PortalInfo, Thunderstorm = PortalInfo,
  },
}
PortalInfo = {
  Id = "Breeze",
  Zone = BasePart,                 -- invisible, CanCollide=false, flat cylinder/box ~14x6x14 studs
                                   --   standing area; PortalService detects players inside it
  Center = Vector3,                -- world position of the zone centre
  Billboard = BillboardGui,        -- parented to a portal part; holds the TextLabels below
  TitleLabel = TextLabel,          -- difficulty name (Theme "Title")
  CountLabel = TextLabel,          -- "0 / 4 players" (Theme "Display"); PortalService updates .Text
  StatusLabel = TextLabel,         -- "Waiting for players" / "Starting in 12s" (Theme "Body")
}
```
Contents (make it genuinely pleasing, hobby-project cosy, no assets):
* Big round plaza cloud (clustered overlapping spheres/cylinders, `SmoothPlastic`, near-white,
  slightly translucent underside) with soft puffy rim; smaller floating cloud islands connected by
  cloud bridges/steps; some islands have a bench, a lantern tree, flowers (parts), a tiny pond.
* A rainbow arch built from 6 coloured neon arc segments (use thin rotated Parts) over the plaza.
* Three **portal gates** on a ring (radius `Config.Lobby.PortalRingRadius`): ring of Neon parts in
  the difficulty colour, swirling `ParticleEmitter` (sparkles texture), `PointLight`, a stand-on pad
  (the Zone), and the BillboardGui with the title/count/status labels + star count of the difficulty
  (a `Theme "Label"` text like "★★☆").
* A welcome sign with the game name (SurfaceGui or BillboardGui, `Theme "Title"` font with a
  `UIGradient`) and a small “How to play” board: WASD move · Shift run · Q dash · Space jump · stand
  in a portal to form a party (Theme "Body").
* Floating decorative cloud puffs drifting slowly (looped tweens) and fireflies/sparkle emitters.
* A `SpawnLocation` is NOT used; players are placed with `SpawnCFrame`.
* A non-collidable "Lobby kill plane" is not needed; PlayerService teleports players back if
  `root.Position.Y < Config.Lobby.KillY`.
* Everything parented under one Folder named `NimbusLobby` in workspace. Keep part count
  reasonable (< ~900 parts), `Anchored = true`, `CastShadow = false` for small parts.

### PlayerService — `PlayerService.lua`
Per-player lifecycle, spawn placement, humanoid setup, leaderstats, lobby rules.
```lua
PlayerService.Init(lobbyInfo)                  -- lobbyInfo from LobbyBuilder.Build()
PlayerService.SetSpawnProvider(fn)             -- fn(player) -> CFrame|nil ; nil => lobby spawn
PlayerService.SendToLobby(player)              -- clears InMatch/Downed, heals, pivots to lobby spawn
PlayerService.GetLobbySpawnCFrame() -> CFrame
PlayerService.ApplyHumanoidStats(player)       -- WalkSpeed/JumpPower/MaxHealth/Health, UseJumpPower
```
Behaviour:
* On `PlayerAdded`: create `leaderstats` folder with IntValue `Tokens` (mirrors attr
  `CloudTokens`), load data via `DataService.Load(player)` (pcall-safe; defaults to 0), set attrs
  `CloudTokens`, `MatchTokens=0`, `InMatch=false`, `Downed=false`.
* On `CharacterAdded`: wait for `HumanoidRootPart` & `Humanoid` (`WaitForChild`, timeout 10),
  `ApplyHumanoidStats`, set `UseJumpPower=true`, hide the default health bar is a CLIENT job (see
  HudController) — server does nothing for that. Pivot the character to
  `SpawnProvider(player) or lobby spawn` (scatter lobby spawns by a few studs so players don't
  stack). Add a brief spawn `ForceField`-free i-frame via `DamageService.GrantInvulnerability`.
* When a character dies for any reason (reset button, etc.) the normal respawn flow applies and
  the SpawnProvider decides lobby vs checkpoint; the death inside a match is handled by
  MatchService (it treats it as a KO — see MatchService).
* A 0.5s loop: any player in the lobby (`InMatch == false`) whose root `Position.Y <
  Config.Lobby.KillY` is sent to the lobby spawn (no damage). In the lobby, health is
  continuously restored to max (lobby is safe).
* `PlayerRemoving`: `DataService.Save(player)` then cleanup.
* `Humanoid.WalkSpeed` is set to `Config.Physics.WalkSpeed`; the CLIENT raises it while running
  (the server accepts speeds up to `RunSpeed`; no anti-cheat required for a hobby game).

### DataService — `DataService.lua`
```lua
DataService.Load(player) -> table   -- { Tokens = number }, never errors, defaults {Tokens=0}
DataService.Save(player)            -- pcall, retries once, silent in Studio w/o API access
DataService.StartAutosave()         -- loop every Config.Tokens.AutosaveSeconds, stoppable by shutdown
DataService.BindToClose()           -- game:BindToClose saves everybody
DataService.AddTokens(player, n)    -- updates attr CloudTokens + leaderstats Tokens, marks dirty
DataService.GetTokens(player) -> number
```
Uses `DataStoreService:GetDataStore(Config.Tokens.DataStoreName)`, key `"u_"..UserId`,
`UpdateAsync` or `SetAsync` in pcall. In-memory cache so everything still works when the DataStore
is unavailable.

### DamageService — `DamageService.lua`
Single entry point for health changes. The only module allowed to change `Humanoid.Health` of a
player during gameplay (apart from PlayerService restoring health in the lobby).
```lua
DamageService.Init()
DamageService.Damage(player, amount, sourceKind, opts) -> boolean   -- true if damage applied
   -- sourceKind in Config.Damage.Kinds; opts: {IgnoreIFrames=bool, KnockbackFrom=Vector3?, Knockback=number?}
DamageService.Heal(player, amount) -> number                         -- returns amount actually healed
DamageService.HealFraction(player, fraction)                         -- fraction of max health
DamageService.SetHealthFraction(player, fraction)
DamageService.GrantInvulnerability(player, seconds)
DamageService.IsInvulnerable(player) -> boolean
DamageService.IsDowned(player) -> boolean
DamageService.Revive(player)                                         -- Downed -> up with ReviveHealthFraction
DamageService.PlayerDowned                                           -- Util.Signal; Fire(player, sourceKind)
```
Rules:
* In the lobby (`InMatch == false`) `Damage` returns false (no damage).
* In a match: subtract from `Humanoid.Health`. NEVER let health reach 0 (that kills the character):
  if the hit would reach <= 0, set `Humanoid.Health = Config.Damage.DownedHealth`, set attr
  `Downed = true`, set `WalkSpeed = 0`, `JumpPower = 0`, make the character semi-transparent
  (LocalTransparencyModifier-style: set `Transparency` 0.55 on character parts + restore on revive),
  fire `PlayerDowned`. Downed players ignore further damage.
* `Damage` respects i-frames (`Config.Damage.IFrames`), then fires remote `DamageTaken(amount, kind)`
  to that player only. Optional knockback: apply an impulse to HumanoidRootPart away from
  `KnockbackFrom`.
* `Revive`: restore transparency, WalkSpeed/JumpPower from Config.Physics, Downed=false, set
  health to `max * ReviveHealthFraction`, grant 2s i-frames.
* Clean up all per-player state on `PlayerRemoving` / `CharacterRemoving`.

### TokenService — `TokenService.lua`
```lua
TokenService.Init()
TokenService.Watch(container, matchHandle) -> stopFn
   -- connects Touched on every descendant tagged Config.Tags.CloudToken inside `container`
   -- matchHandle = { AddTokens = function(player, n) end }   (provided by MatchService)
   -- on first valid touch by a non-downed player: token.Visible effect (small burst + tween out),
   -- Destroy it, call matchHandle.AddTokens(player, value). Server-side debounce so a token can
   -- never be collected twice.
TokenService.MakeTokenPart(position, parent, value) -> Part
   -- THE visual cloud token: a golden glowing coin-cloud (Cylinder oriented upright, Neon gold, with
   -- a small white puff, PointLight, sparkles, billboard "★" optional), tagged CloudToken,
   -- attr Value, CanCollide=false, Anchored. Slowly spins + bobs via a looped tween
   -- (Tween on CFrame is fine; or a single shared Heartbeat driver for all tokens in the container).
```
CourseBuilder/LobbyBuilder call `TokenService.MakeTokenPart` to create tokens (do NOT duplicate the
visual). The lobby may contain a few decorative tokens that are not tagged (no collection).

### HazardService — `HazardService.lua`
Brings tagged course parts to life and applies damage via DamageService.
```lua
HazardService.Attach(container, matchHandle) -> stopFn
   -- finds descendants of `container` carrying the tags in Config.Tags and starts the behaviour.
   -- stopFn() stops every loop/connection (called on match end, before destroying container).
   -- matchHandle = { IsActive = function() -> bool }  hazards pause when false
```
Behaviours (parameters read from attributes, with sane defaults when missing):
| Tag | Behaviour |
|---|---|
| `SpinBar` | rotate around its Y axis at `Speed` deg/s (CFrame each Heartbeat from a base CFrame, one shared Heartbeat connection for all bars); `Touched` by a player → `Damage(p, Damage or 15, "SpinBar", {KnockbackFrom = bar.Position, Knockback = 55})` |
| `StormCloud` | dark cloud volume with rain `ParticleEmitter`; players inside (`GetPartBoundsInBox` poll at 4 Hz) take `DPS/4` per tick as `"Storm"` (IgnoreIFrames = true) |
| `LightningZone` | every `Interval` (default 4s, ±jitter) show a red glowing warning disc for `Warning` s (default 1.2), then a bolt (Neon beam part) strikes; players in the radius take `Damage` (default 28, `"Lightning"`) + flash + thunder-free (no sounds) |
| `VanishCloud` | when a player stands on it (Touched), after `VanishDelay` (default 0.9s) it fades (Transparency tween), `CanCollide=false`, returns after `ReturnDelay` (default 3.5s) |
| `MovingCloud` | tween the part between its start CFrame and start + `EndOffset` over `Period` s, Sine in/out, looped back/forth forever; players standing on it move with it (Roblox does this natively for Anchored parts moved by CFrame tweens? NO — use `AssemblyLinearVelocity`-free approach: make the part non-anchored is wrong. Use a Heartbeat that sets CFrame on the anchored part; characters on moving anchored parts DO NOT inherit motion, so also nudge standing players: each Heartbeat, for players whose root is within the part's top area, add the part's per-frame delta to the root CFrame) |
| `BouncePad` | on Touched by a player, `HumanoidRootPart.AssemblyLinearVelocity = Vector3.new(h.X, Power or 90, h.Z)` where `h` is the player's horizontal velocity, rescaled to the pad's `LaunchSpeed` attribute (same heading) when the player is moving (> 2 studs/s); a standing player bounces straight up. `LaunchSpeed` defaults to 0 = keep the player's own speed (server sets; debounce 0.3s) plus squash tween |
| `PressurePlate` + `PlateBridge` | matching `BridgeId`. Bridge parts are visible+collidable **only while at least one player stands on any plate with that id** (poll 5 Hz via `GetPartBoundsInBox`); retract with a quick fade 1.0s after the last player leaves. Co-op mechanic: someone must hold the plate while teammates cross |

Everything created at runtime (warning discs, bolts) parented inside `container`. All loops check a
`stopped` flag.

### CourseBuilder — `CourseBuilder.lua`
Procedural co-op parkour generator. Split into a **pure layout generator** (no Instances, unit-testable)
and a **builder**.
```lua
CourseBuilder.GenerateLayout(difficultyId, seed) -> Layout
CourseBuilder.ValidateLayout(layout) -> ok:boolean, problems:{string}
CourseBuilder.Build(layout, origin, parent) -> CourseInfo
```
`GenerateLayout` is deterministic for `(difficultyId, seed)` and uses only `Config`, `Util.NewRng`
and Vector3 math. Layout (all positions are relative to origin (0,0,0), progression toward +Z):
```lua
Layout = {
  DifficultyId = "Gale", Seed = 1234,
  Steps = {  -- in order of travel
    { Index = 1, Stage = 0, Kind = "Start",      Pos = Vector3, Size = Vector3 },  -- Pos = CENTRE of top surface
    { Index = 2, Stage = 1, Kind = "Platform",   Pos, Size, Gap = number },        -- Gap = edge-to-edge distance from previous step
    ... Kind in: "Start","Platform","Checkpoint","Moving","Vanishing","Bounce","SpinBarPlatform",
        "StormPlatform","LightningPlatform","PlateBridge","DashGap","Finish"
    each step may carry: Tokens = { Vector3 offsets above top surface }, Hazard = {...} (kind params)
  },
  Checkpoints = { [1] = stepIndex, ... },   -- one per stage; the last stage ends at the Finish
  TotalTokens = number,
  Bounds = { Min = Vector3, Max = Vector3 },
}
```
Guarantees (the validator checks all of them; the generator must satisfy them):
* Edge-to-edge horizontal gap between consecutive *walkable* steps is within
  `[difficulty.GapMin, difficulty.GapMax]`, except `DashGap` steps whose gap is within
  `[DashGapMin, DashGapMax]` (and must be `<= 0.85 * Config.Physics.MaxDashGap`, `> Config.Physics.MaxRunGap * 0.75`)
  — these are the ONLY gaps that require a dash and a `Dash` hint sign (an arrow of Neon parts
  + "DASH!" via `Theme "Accent"`) is placed on the platform before them.
* Rise: `0 <= nextTopY - prevTopY <= difficulty.RiseMax` and, ALWAYS, `<= Config.Physics.JumpHeight * 0.7`.
  Drops (negative rise) are allowed up to -4 only.
* Net direction is +Z; lateral wander (X) allowed within ±35 studs from the centre line, and the
  platforms never overlap/intersect each other (min 2 studs separation from any non-adjacent step).
* Platform sizes within `[PlatformMin, PlatformMax]`; Checkpoint platforms >= 14x14; Start >= 24x24
  with room for 4 players; Finish >= 28x28.
* Exactly `difficulty.Stages` checkpoints (the last one right before the Finish) and every stage has
  `StepsPerStage` steps. Co-op `PlateBridge` stage elements appear on Gale/Thunderstorm (at most one
  per stage; their plate sits on a side platform reachable without the bridge).
* Token offsets sit 3–4.5 studs above a step top, never inside geometry, on at least
  `TokensPerStage` steps per stage, some on slightly risky edges.
* Each hazard step references numeric params only (Speed, Damage, DPS, Interval, Period, EndOffset...).

`Build` creates real Parts under a Folder named `Course_<seed>` in `parent` and returns
```lua
CourseInfo = {
  Folder = Folder,
  StartCFrame = CFrame,                 -- world CFrame on the start platform (players spawn around it)
  Checkpoints = { [i] = { Part = BasePart, Index = i, SpawnCFrame = CFrame, Stage = number }, ... },
  Finish = BasePart,                    -- tagged FinishPad
  KillY = number,                       -- origin.Y - 60
  TotalTokens = number,
  TotalSteps = number,
}
```
Visuals: cloud-like platforms (white `SmoothPlastic`; vary: rounded Cylinder/Ball clusters or rounded
Block with `Material.SmoothPlastic`; coloured trim in the difficulty colour on platform edges),
checkpoint pads as glowing flag-poles with banners and a `BillboardGui` ("Checkpoint 2/6",
Theme "Title"), Start platform with a "START" sign and arch, Finish platform with a rainbow-ringed
goal and "FINISH" sign. Tag parts exactly per `Config.Tags` & attributes listed there. Tokens via
`TokenService.MakeTokenPart`. Anchored everywhere. Keep < ~1500 parts.
Atmosphere extras (cheap): distant decorative cloud puffs below/around the route.

### MatchService — `MatchService.lua`
Match lifecycle + team rules. Owns the in-match state machine.
```lua
MatchService.Init(deps)                         -- deps = { PlayerService=, DamageService=, DataService=,
                                                --          HazardService=, TokenService=, CourseBuilder= }
MatchService.StartMatch(difficultyId, players) -> match|nil   -- nil if slots exhausted
MatchService.GetMatchOf(player) -> match|nil
MatchService.GetRespawnCFrame(player) -> CFrame|nil           -- SpawnProvider: team checkpoint spawn (scattered), else nil
MatchService.LeaveMatch(player)                               -- player returns to lobby; may end match
MatchService.MatchEnded                                       -- Util.Signal; Fire(match, won:boolean)
```
`match` = `{ Id, DifficultyId, Slot, Players = {Player...}, Alive = set, State, Course = CourseInfo,
Checkpoint = number, StartedAt, ... }`.
Flow:
1. **Setup**: pick the lowest free slot (≤ `MaxConcurrent`), origin as in "Shared conventions",
   `layout = CourseBuilder.GenerateLayout(id, seed)` (seed from `os.time()` + slot),
   `CourseBuilder.Build(layout, origin, workspace)`, `HazardService.Attach`, `TokenService.Watch`.
2. **Intro**: teleport all players to `StartCFrame` (scattered ±6 studs), set `InMatch = true`,
   reset `MatchTokens = 0`, heal fully, freeze them (`WalkSpeed = 0`, JumpPower 0) for
   `IntroCountdown` seconds while broadcasting `MatchState{Phase="Countdown", Seconds=n}` every second.
3. **Playing**: unfreeze. Broadcast `MatchState` to members at 2 Hz (see payload below). Watch
   checkpoints (`Touched` on checkpoint parts or a 5 Hz proximity poll): when an alive player first
   touches checkpoint `i > match.Checkpoint`: set `match.Checkpoint = i`, notify the team
   (`Notify "Checkpoint i/N reached!" good`), heal all alive `CheckpointHealFraction`, **revive all
   downed teammates** at that checkpoint (teleport them to its SpawnCFrame, `DamageService.Revive`),
   and flash a banner. Kill plane: every 0.25 s, any member whose root `Y < course.KillY` takes
   `Config.Damage.VoidDamage[id]` (`"Void"`), and if still up is teleported to the team checkpoint
   SpawnCFrame (Start if none); if downed by it, they are teleported to the checkpoint as downed.
   Downed players stay frozen where they are and wait for a teammate to reach the next checkpoint
   (they are NOT respawned automatically) — BUT if no alive player remains → **defeat**.
   `AddTokens(player, n)`: `MatchTokens += n` and `DataService.AddTokens(player, n)`;
   `Notify "+n"` with kind `token` to that player.
4. **Finish**: `Touched` on Finish pad by an alive player (or proximity poll): that player is marked
   finished (frozen safely on the pad, invulnerable). When **all alive** players have finished →
   **victory**. Time limit (`difficulty.TimeLimit`) expires → **defeat**.
5. **End**: broadcast `MatchResult` to each member:
   `{ Won=bool, Reason="victory"|"defeat"|"timeout"|"abandoned", Seconds=n, MatchTokens=n, Bonus=n, DifficultyId, DifficultyName, TotalTokens=course.TotalTokens, Members={{Name, MatchTokens, Finished, Downed}} }`.
   On victory award `Config.Match.TokenBonusOnWin[id]` to every finished player via
   `DataService.AddTokens`. After `EndScreenSeconds`, send everyone to the lobby
   (`PlayerService.SendToLobby`), `InMatch=false`, clear states (send `MatchState = nil`), destroy
   the course (call the stop functions first), free the slot, fire `MatchEnded`.
* If every member leaves → end quietly (`"abandoned"`).
* A character that dies for any reason in a match (e.g. reset button) → treat as a KO via
  `DamageService` (downed) — implement by listening to `Humanoid.Died` and, after respawn, placing
  the player at the team checkpoint and marking them downed unless a teammate reaches the next
  checkpoint... Simplest acceptable behaviour: respawn at the team checkpoint with
  `ReviveHealthFraction` health and a 10 s respawn penalty? **Pick this: respawn at checkpoint
  immediately, 50% health, no penalty** (reset-button deaths shouldn't strand people).
* `Remotes.LeaveMatch.OnServerEvent` → `LeaveMatch(player)`.

`MatchState` payload (server → members, nil when not in a match):
```lua
{ Phase = "Countdown"|"Playing"|"Ended", DifficultyId, DifficultyName, Color = Color3,
  Seconds = number,               -- countdown seconds left, or time left in Playing
  Checkpoint = number, TotalCheckpoints = number,
  TokensCollected = number, TotalTokens = number,           -- team totals
  Members = { { UserId, Name, Health = fraction, Downed = bool, Finished = bool, Tokens = number } } }
```

### PortalService — `PortalService.lua`
Forms parties at the lobby portals.
```lua
PortalService.Init(lobbyInfo, MatchService)   -- connects to lobbyInfo.Portals, starts the zone poll
PortalService.RemovePlayer(player)            -- leave current party (no-op if none)
PortalService.GetParty(portalId) -> { Players = {Player...}, Countdown = number|nil }
```
Behaviour:
* Poll at 5 Hz: a player (not `InMatch`, alive) standing inside a portal `Zone` (check
  `root.Position` against the zone's box using `Zone.CFrame:PointToObjectSpace`) joins that portal's
  party (max `Config.Match.MaxPlayers`; if full show `Notify "Party is full" bad` once). A player
  who walks out of the zone leaves the party (so the zone is the "ready pad").
* Party countdown starts when the first player joins: `Config.Match.PartyCountdown` seconds, shortened
  to `FullPartyCountdown` when the party fills. If the party empties, reset. When it hits 0 and
  `#players >= MinPlayers` → `MatchService.StartMatch(portalId, players)`; the party is cleared.
  If StartMatch returns nil (servers busy) → `Notify "All sky arenas are busy, try again soon" bad`.
* Update `PortalInfo.CountLabel.Text` ("2 / 4"), `StatusLabel.Text` ("Waiting for players…" /
  "Starting in 12s" / "Party full!") live.
* Fire `PartyState` to each member every second:
  `{ PortalId, DifficultyName, Color, Players = {{UserId, Name}}, Max, Countdown = number|nil }`;
  fire `PartyState(nil)` when a player leaves/starts.
* `Remotes.LeaveParty.OnServerEvent` → the player is removed AND gets a short (3 s) re-join lockout
  so they can step out; (they also need to walk out of the zone — teleport them 12 studs outward from
  the portal centre).
* Clean up on `PlayerRemoving`.

### Main — `Main.server.lua`  (Script)
Boot order: `Remotes.Init()`, `LightingService.Init()`, `lobbyInfo = LobbyBuilder.Build()`,
`DamageService.Init()`, `TokenService.Init()`, `PlayerService.Init(lobbyInfo)`,
`DataService.StartAutosave()`, `DataService.BindToClose()`,
`MatchService.Init({...})`, `PlayerService.SetSpawnProvider(MatchService.GetRespawnCFrame)`,
`PortalService.Init(lobbyInfo, MatchService)`; wire `Remotes.Dash.OnServerEvent`: per-player
cooldown (`DashCooldown * 0.8` tolerance) → `Remotes.DashFx:FireAllClients(player.UserId)`.
Also: `Remotes.LeaveParty` / `LeaveMatch` are connected by their owners. Wrap each init in
`pcall` + `warn` so one failing service doesn't brick the server. `print("[NimbusClimb] ready")`.

---

## Client modules (`src/client/Controllers/`)

### MovementController — `MovementController.lua`
```lua
MovementController.Init()
```
* **Run**: hold LeftShift (PC) / a mobile "RUN" toggle button / gamepad ButtonL3 → walk speed to
  `Config.Physics.RunSpeed` (smooth lerp), drains `Stamina`; stamina regen when not running.
  Cannot run at 0 stamina (hysteresis: resume at 15).
* **Dash**: Q (PC), ButtonB-ish (gamepad ButtonB), a mobile "DASH" button. Costs stamina
  (`DashStaminaCost`), cooldown `DashCooldown`. Dash direction = `Humanoid.MoveDirection` if non-zero
  else camera look vector flattened. Implementation: for `DashDuration` seconds set
  `HumanoidRootPart.AssemblyLinearVelocity` to `dir * DashSpeed` keeping current Y velocity
  (use a `LinearVelocity` constraint with `MaxForce` finite OR set velocity every Heartbeat; clean up
  reliably, also when the character dies). Allowed in air. Fires `Remotes.Dash`. Adds a speed-line /
  trail effect (Trail between two Attachments or a few translucent Neon parts fading) and a FOV
  punch (Camera FieldOfView tween 70→82→70).
* Mirrors `Stamina` into `LocalPlayer:SetAttribute(Config.Attr.Stamina, value)` (0..MaxStamina) so
  the HUD can read it, and exposes `MovementController.GetDashCooldownFraction()` (0 ready .. 1).
* Disabled when the player is `Downed` (attribute) — no run/dash.
* Re-binds on every `CharacterAdded`; all connections cleaned on `CharacterRemoving`.
* Mobile: create the buttons in a ScreenGui "MobileControls" only when `UserInputService.TouchEnabled`;
  styled via Theme (rounded, `Theme.Fonts.Heading`).
* Optional polish: soft footstep dust `ParticleEmitter` while running; slight camera FOV widening
  while running.
* Also sets camera: `LocalPlayer.CameraMaxZoomDistance = 40`.

### HudController — `HudController.lua`
```lua
HudController.Init()
```
A single ScreenGui "NimbusHud" (`ResetOnSpawn = false`, `IgnoreGuiInset = true`). Disable the default
health bar and the default player list (the `leaderstats` panel would overlap the token counter):
`StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)` and `(Enum.CoreGuiType.PlayerList, false)`, each in its
own pcall inside a retry loop, and re-applied whenever `StarterGui.CoreGuiChangedSignal` re-enables either one (the
default backpack/emotes stay untouched). Elements (all fonts through Theme):
* **Health bar** bottom-left: rounded panel, animated fill (tween on `Humanoid.HealthChanged`),
  colour via `Theme.HealthColor`, heart icon (a "♥" TextLabel, no images), text "78 / 100"
  (`Theme "Display"`), a lagging "damage trail" bar, low-health pulse (<30%). When `Downed` attr is
  true show "DOWNED — wait for a teammate!" (`Theme "Accent"`) in red.
* **Stamina bar** under it (thin, `Theme.Colors.Stamina`) with a small dash-cooldown pip.
* **Cloud token counter** top-right: golden "☁" + session total (`CloudTokens`) and, when in a match,
  "this run: N" (`MatchTokens`); count-up tween and a pop animation when it increases.
* **Match panel** top-centre while `MatchState` is non-nil: difficulty name in its colour
  (`Theme "Title"`), timer (`Theme "Display"`, `Util.FormatTime`), "Checkpoint 2/6" with a progress
  bar, "Tokens 7/24", and a compact team list (name + mini health bar + ✔/💀 state) — update at the
  `MatchState` rate; **countdown** phase shows a huge centred "3 2 1 GO!" (`Theme "Accent"`),
  scale-punch per number.
* **Party panel** (lobby only, `PartyState` non-nil): "Party – Soft Breeze", player names,
  "Starting in 12s", and a "Leave" button (`Theme "Heading"`) → `Remotes.LeaveParty:FireServer()`.
* In a match a small "Leave match" button → `Remotes.LeaveMatch:FireServer()` (confirm by pressing twice).
* Game title card "NIMBUS CLIMB" + tagline (`Theme "Title"`/`"Script"`) fades in at join and out after 4s.

### DamageFx — `DamageFx.lua`
```lua
DamageFx.Init()
```
* On `Remotes.DamageTaken(amount, kind)`: red screen-edge vignette flash (a Frame with
  `UIGradient`/ImageLabel-free radial look made from 4 gradient frames), camera shake (short, using
  `Humanoid.CameraOffset` tween), floating damage number above the player's head (BillboardGui,
  `Theme "Accent"`, rises + fades, colour by kind) and a short “Ouch” style kind label
  (e.g. "ZAP!" for Lightning, "WHACK!" SpinBar, "SPLASH" Void, "DRIZZLE" Storm).
* Also shows floating "+n ☁" when tokens increase (watch `MatchTokens` attribute deltas) at the
  character's head.
* Handles `Notify` toasts? NO — that is NotifyController.

### NotifyController — `NotifyController.lua`
```lua
NotifyController.Init()
```
* `Remotes.Notify(text, kind, duration)` → toast stack (top-centre below the match panel; max 4,
  slide/fade in+out; `Theme "Body"`/`"Heading"`; colour by kind info/good/bad/token).
* `Remotes.MatchResult(result)` → a big centred results card: VICTORY! / DEFEAT (`Theme "Title"`,
  gradient), difficulty, time (`Util.FormatTime`), tokens collected, bonus, member table, and a
  “Returning to the lobby in Ns…” line counting down `Config.Match.EndScreenSeconds`.
* `Remotes.DashFx(userId)` (other players only; ignore own): spawn a brief fading trail/puff at that
  player's character (cheap).

### Main — `Main.client.lua` (LocalScript)
`require` the four controllers and `Init()` each inside `pcall` + `warn`.

---

## Tooling (`tools/`)

* `tools/check.mjs` — Node script using the `luaparse` npm package (`npm i --no-save luaparse` in
  a scratch dir or `tools/`): for every `*.lua` in `src/` it (a) parses as Lua 5.3, (b) rejects
  Luau-only syntax, (c) finds **undefined globals** against a Roblox allowlist (built-in
  Roblox + Lua globals) and reports `file:line name`, (d) flags use of deprecated `wait(`, `spawn(`,
  `delay(`, (e) flags raw `Enum.Font.` outside `Theme.lua`. Exit code 1 on any finding.
* `tools/smoke.py` + `tools/robloxmock.lua` — a permissive Roblox-API mock running on `lupa`
  (`pip install lupa`): fake `game:GetService`, `Instance.new`, `Vector3`, `CFrame`, `Color3`,
  `UDim2`, `Enum` (proxy returning any name), `Random`, `task`, signals. Boots every shared and
  server module, runs `CourseBuilder.GenerateLayout/ValidateLayout` for all difficulties over 200
  seeds, simulates a `MatchService` lifecycle with fake players and a fake clock (victory, defeat,
  abandon) and asserts invariants; also loads the client controllers.
* `tools/run_checks.sh` runs both.
