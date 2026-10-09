# Nimbus Climb — v2 contract (pets, spots, 5 difficulties, new UI)

**This file supersedes `ARCHITECTURE.md` wherever they disagree.** Read `ARCHITECTURE.md` first for the
base game (match flow, damage, tokens, remotes, language rules), then this file. `src/shared/Config.lua`
is already updated for v2 — read it; it is the source of truth for names and numbers.

## What the player asked for (the goals)

1. **More different, unique parkours.** Not one straight line any more: several overall shapes
   (archetypes) and many stage themes, mixed per seed, so every run feels different.
2. **Five portals by level:** `Easy`, `Medium`, `Hard`, `Extreme`, `Saint` (replaces Breeze/Gale/Thunderstorm
   everywhere). Add more fun mechanics (cannons, wind, pendulums, golden bonus tokens...).
3. **Colours are far too bright.** Lower the overall brightness, clearer, more contrasty, calmer colours.
   Platforms must read clearly against the sky.
4. **Bigger lobby + personal spots.** Every player owns a *spot* (their own cloud home) in the lobby where their
   stuff (pets) is shown and saved.
5. **Pets.** Winged cute creatures (style: chibi big-head animals, colourful, glowing eyes, like a Pet-Simulator
   style lineup) that **fly next to their owner** like Bee Swarm Simulator bees. Bought from the shop **with cloud
   tokens** by buying a **roulette** that gives a mystery pet. Rarity scales with roulette price.
6. **Game icon**: the main pet, the **Cloudy Dragon**, is the icon.
7. **UI system** in the style of chunky Pet-Simulator panels (thick dark outline, glossy cyan/blue panels, green
   buttons, red close X, round icon buttons) but **cloudier** to fit our theme.
8. **Inventory, item slots, HP bar and more** (stats, hotbar with usable items).
9. **No system text in the middle of the screen.** All game-system messages (toasts, countdown, results, title card)
   are small, on the side, with a cool font.

## Global rules (unchanged + additions)

* Plain Lua 5.1-compatible syntax only; Roblox globals allowed; `task.*` only; no external asset ids.
* Fonts only via `Theme` roles. UI built in code only.
* **No colour may be pure white or maximum-saturation neon at large sizes.** Use the dimmer palette in `Theme`.
  `Neon` material only for small accents (rings, eyes, tokens, trims), never for big surfaces.
* Never put system output in the centre of the screen (see "Screen layout map").
* Server authoritative: pets/items/tokens are validated server-side. Every client->server remote is rate-limited
  (~0.25 s per player per remote) and its arguments are type-checked (`type(x) == "string"`, known ids only).

## Ownership (who writes which file — never edit files you do not own)

| Agent | Files |
|---|---|
| lobby | `server/Services/LobbyBuilder.lua` |
| layoutgen | `server/Services/CourseLayout.lua` (pure layout generator + validator) |
| coursebuild | `server/Services/CourseBuilder.lua` (geometry, tags, scenery; written AFTER layoutgen finishes, reads `CourseLayout.lua`) |
| hazards | `server/Services/HazardService.lua`, `server/Services/TokenService.lua` |
| match | `server/Services/MatchService.lua`, `server/Services/PortalService.lua` |
| economy | `server/Services/DataService.lua`, `server/Services/PetService.lua`, `server/Services/ItemService.lua` |
| world | `server/Services/PlayerService.lua`, `server/Services/LightingService.lua`, `server/Services/SpotService.lua`, `server/Services/DamageService.lua`, `server/Main.server.lua` |
| catalog | `shared/PetCatalog.lua`, `shared/ItemCatalog.lua` |
| petvisual | `shared/PetBuilder.lua` |
| uikit | `shared/Theme.lua`, `client/UI/CloudUI.lua`, `client/State.lua` |
| hud | `client/Controllers/HudController.lua`, `client/Controllers/NotifyController.lua`, `client/Controllers/DamageFx.lua` |
| menu | `client/Controllers/MenuController.lua`, `client/Controllers/HotbarController.lua` |
| petclient | `client/Controllers/PetController.lua`, `client/Controllers/MovementController.lua`, `client/Main.client.lua` |
| icon | `branding/*` |
| tooling (later) | `tools/*`, `README.md` |

`shared/Config.lua`, `shared/Util.lua`, `shared/Remotes.lua`, both architecture docs are owned by the lead.

Require paths: shared -> `local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")`.
Server siblings -> `require(script.Parent.X)`. Client controllers: `local Client = script.Parent.Parent`, then
`require(Client.UI.CloudUI)`, `require(Client.State)`, `require(script.Parent.OtherController)`.

---

## 1. Data model (economy agent: `DataService`)

Profile (saved per player in DataStore `Config.Tokens.DataStoreName`, key `"u_"..UserId`; migrate v1 saves
(`{Tokens=n}` in `LegacyDataStoreName`) once; all DataStore calls in pcall; in-memory cache so everything works
without API access):
```lua
Profile = {
  Version = 2,
  Tokens = 0,
  Pets = { [petId] = count },          -- owned stacks, count 1..Config.Pets.MaxPerStack
  Equipped = { petId, ... },           -- at most Config.Pets.MaxEquipped entries; a petId may appear at most `count` times
  Items = { [itemId] = count },        -- 0..Config.Items.MaxCarry
  Stats = { Matches = 0, Wins = 0, TokensEarned = 0, Spins = 0, BestTimes = { [difficultyId] = seconds } },
  SpotIndex = nil,                     -- last spot used, preferred on next join if free
}
```
```lua
DataService.Load(player) -> Profile            -- never errors; also sets attrs CloudTokens (+ leaderstats Tokens)
DataService.Save(player)  DataService.StartAutosave()  DataService.BindToClose()
DataService.GetProfile(player) -> Profile|nil  -- the LIVE table (mutate then MarkDirty + Sync)
DataService.MarkDirty(player)
DataService.AddTokens(player, n)               -- n may be negative only via SpendTokens; updates attr + leaderstats
DataService.SpendTokens(player, n) -> boolean  -- false if insufficient (never goes negative)
DataService.GetTokens(player) -> number
DataService.Sync(player)                       -- fires remote ProfileSync(snapshot) to that player
DataService.RecordMatch(player, difficultyId, won, seconds)   -- updates Stats (BestTimes on win)
DataService.ProfileLoaded                      -- Util.Signal; Fire(player, profile) after load
```
`ProfileSync` snapshot (what the client receives — plain tables only, no Instances):
```lua
{ Tokens = n, Pets = {[petId]=count}, Equipped = {petId,...}, Items = {[itemId]=count},
  Stats = { Matches, Wins, TokensEarned, Spins, BestTimes = {[diffId]=sec} },
  SpotIndex = n|nil,
  Perks = { MaxHealth = 0.12, TokenBonus = 0.25, StaminaRegen = 0, CheckpointHeal = 0 } }   -- summed, capped
```
Sent on join (after load), on `RequestProfile`, and after every Pet/Item mutation. Token changes are visible to the
client through attribute `CloudTokens` (not through ProfileSync).

**Leaving during a DataStore outage (orphan retention, see section 12).** A leaving player's cache entry is freed only
once the store holds everything it knows. If the final save fails (outage, throttling, a load that never succeeded) the
entry is kept as an *orphan*: a quick rejoin gets the unsaved profile back, a background retry (first after 10 s, backoff
up to 120 s) and the autosave sweep (which walks the cache, not the player list) flush it, `BindToClose` flushes it, and it
is dropped only after a successful write or after 30 minutes (with a `giving up` warning). `DataService.Release(player)`
makes that decision; callers just call it.

## 2. Pets

### `shared/PetCatalog.lua` (catalog agent) — data + pure logic, no Instances
```lua
PetDef = {
  Id = "cloudy_dragon", Name = "Cloudy Dragon", Rarity = "Mythic", Blurb = "...",
  Look = {                         -- consumed by PetBuilder; every field required except Accessory/Glow
    Species   = "Dragon",          -- one of PetCatalog.Species (see below)
    Primary   = Color3, Secondary = Color3, Eye = Color3,
    Glow      = false,             -- eyes + wing edges glow (Neon) for glow=true
    Accessory = "Horns",           -- nil | "Horns" | "Crown" | "Halo" | "Leaf" | "Mushroom" | "Scarf" | "Antlers" | "Flower"
    WingStyle = "Cloud",           -- "Feather" | "Bat" | "Fairy" | "Cloud" | "Crystal" | "Flame"
    WingColor = Color3,
  },
  Perks = { MaxHealth = 0.10, TokenBonus = 0.25 },    -- keys from Config.Pets.PerkCaps only; fractions
}
PetCatalog.Species = { "Cat","Dog","Fox","Bunny","Bear","Panda","Dragon","Owl","Slime","Unicorn","Phoenix","Frog","Penguin","Axolotl" }
PetCatalog.Pets          -- array, sorted by rarity order then Name
PetCatalog.ById          -- map
PetCatalog.Get(id) -> PetDef|nil
PetCatalog.ListByRarity(rarityId) -> {PetDef...}
PetCatalog.GetRarity(rarityId) -> {Id, Order, Color}            -- from Config.Rarities
PetCatalog.RollPet(rouletteId, rng) -> petId                    -- weighted: rarity by Roulette.Odds, then uniform pet within rarity;
                                                                --   rng has :Float(a,b) and :Int(a,b) (Util.NewRng); every rarity that has weight > 0
                                                                --   MUST contain at least one pet
PetCatalog.GetOdds(rouletteId) -> { {PetId=, Rarity=, Chance=0..1}, ... }   -- exact, sums to 1
PetCatalog.PossiblePets(rouletteId) -> {PetDef...}
PetCatalog.PerkLabel(perkType, value) -> "+12% Max Health"      -- perk names: MaxHealth "Max Health", TokenBonus "Cloud Tokens", StaminaRegen "Stamina Regen", CheckpointHeal "Checkpoint Heal"
PetCatalog.SumPerks(petIds) -> {MaxHealth=,TokenBonus=,StaminaRegen=,CheckpointHeal=}  -- capped by Config.Pets.PerkCaps
```
Content: **~26 pets**, designed to feel like a Pet-Simulator lineup (cute chibi animals, varied palettes, some
glowing). Counts: Common 6, Uncommon 6, Rare 5, Epic 4, Legendary 3, Mythic 2. Perk strength scales with rarity
(Common ~+2–3%, Mythic ~+10–25%; a pet has 1–2 perks). Names are charming and unique. **Mythic #1 is the
`cloudy_dragon` (id exactly `"cloudy_dragon"`)**: Species Dragon, Primary (236,244,255) cloud white, Secondary
(150,196,240) sky blue, Eye (30,40,90), Accessory "Horns" (gold), WingStyle "Cloud", WingColor (200,225,255),
perks MaxHealth 0.12 + TokenBonus 0.25. Every Roulette in `Config.Roulettes` must be rollable (every rarity listed
in its Odds has pets). Commons/Uncommons are available from the cheap roulettes, Mythics only from Sky/Celestial.

### `shared/ItemCatalog.lua` (catalog agent)
```lua
ItemDef = { Id, Name, Blurb, Price (tokens), Glyph (1 short text/symbol shown on the slot), Color = Color3, Rarity }
ItemCatalog.List   -- array in hotbar order: heal_cloud, shield_bubble, phoenix_feather
ItemCatalog.ById / ItemCatalog.Get(id)
```
* `heal_cloud` "Heal Cloud" — Price 30 — heals 40% of max HP (match only, not downed).
* `shield_bubble` "Shield Bubble" — Price 45 — 8 s invulnerability (match only).
* `phoenix_feather` "Phoenix Feather" — Price 150 — instantly revives the nearest downed teammate in your match
  (50% HP), consumed only if someone was revived.

### `shared/PetBuilder.lua` (petvisual agent) — all pet visuals, usable server- and client-side and in ViewportFrames
```lua
PetBuilder.Build(petDef, opts) -> Model      -- opts: { Scale = 1 }
PetBuilder.Animate(model, t, opts)           -- opts: { Flap = 1 (speed multiplier), Excited = 0..1 }; call every frame
PetBuilder.GetHeight(petDef) -> studs        -- pet's total height at Scale 1
```
Requirements:
* Built **only from Parts** (+ attachments/particles, no assets). **Every part Anchored = true, CanCollide = false,
  CanTouch = false, CanQuery = false, Massless**, `CastShadow = false` on small parts. `Model.PrimaryPart` = body root.
  The caller moves the pet with `model:PivotTo(cframe)`; `Animate` then recomputes every animated sub-part CFrame
  *relative to the PrimaryPart's current CFrame* (so it works in the workspace AND inside a ViewportFrame; no
  welds/Motor6D). Store each animated part's base offset (CFrame value or attribute) at build time.
* Style: chibi — big round head (Ball) with a small round body, short limbs or none (they hover), species-specific
  ears/snout/tail, glossy big eyes (dark ball + tiny white highlight; `Glow` -> Neon iris), blush cheeks, small
  fluffy tail. Total height about 2.2–3 studs at Scale 1 so they sit nicely beside a character. Palette from Look.
  Rarity may add flair: Legendary/Mythic get a soft glow ParticleEmitter (sparkles) — keep particle rates low.
* **Every pet has two wings** (named `WingL`, `WingR`) styled by `WingStyle` (Feather = layered feather panels, Bat =
  webbed wedge, Fairy = 2 pairs translucent, Cloud = 3 puffy spheres each side with soft colour, Crystal = angled
  translucent shards, Flame = orange translucent Neon edges). `Animate` flaps them (sine, ±35°) at `Flap` speed;
  Excited > 0.5 flaps faster. Tail wags/ears twitch subtly.
* **Cloudy Dragon** (`Species = "Dragon"`): sky-blue/white fluffy dragon: round head, two small gold horns, stubby snout
  with two nostril dots, big dark-blue glossy eyes with sparkles, cloud-puff tail tip, cream belly, cloud wings.
  This model must look especially good: it is the game's mascot and matches the icon art in `branding/`.
* Must support every `Species`, `Accessory`, `WingStyle` listed above (unknown values fall back to Cat / none /
  Feather without erroring). Part count per pet <= ~70.

### `server/Services/PetService.lua` (economy agent)
```lua
PetService.Init(lobbyInfo, deps)         -- deps = { DataService = }; connects roulette ProximityPrompts (see LobbyInfo) and remotes
PetService.BuyRoulette(player, rouletteId) -> ok:boolean, result|reason
PetService.Equip(player, petId) -> ok, reason       PetService.Unequip(player, petId) -> ok, reason
PetService.GetEquipped(player) -> {petId...}
PetService.GetPerks(player) -> {MaxHealth=, TokenBonus=, StaminaRegen=, CheckpointHeal=}   -- capped (PetCatalog.SumPerks)
PetService.GetTokenMultiplier(player) -> number >= 1
PetService.PerksChanged                  -- Util.Signal; Fire(player)
```
* `BuyRoulette`: not in a match; known roulette; `DataService.SpendTokens(player, price)`; roll with
  `PetCatalog.RollPet(rouletteId, Util.NewRng(os.time() + userId + spins))`; add to `Profile.Pets` (cap stacks at
  MaxPerStack: if capped, refund the price and fail); stats.Spins += 1; `DataService.Sync`; fire
  `RouletteResult` to the player; first pet owned is auto-equipped if a slot is free; on Rare+ pulls send a `Notify`
  to the whole server (`"<Name> pulled <Pet>!"`, kind "good") — small, at the side.
* `RouletteResult` payload: `{ Ok = bool, Reason = string|nil, RouletteId, PetId = string|nil, IsNew = bool,
  Count = number, Tokens = number, Strip = { petId, ... } }` where `Strip` is a cosmetic list of ~40 pet ids drawn
  from `PossiblePets(rouletteId)` with `PetId` placed at index 34 (client scrolls the strip and stops there).
* `Equip/Unequip`: refused while the player attribute `InMatch` is true (`false, "Pets are locked during a match"`: the
  pets in a match are the ones the player entered with; they work again after the match), validated against ownership
  and `Config.Pets.MaxEquipped`; writes `Profile.Equipped`,
  sets Player attribute `EquippedPets` (csv, used by every client to draw followers) and `PerkStaminaRegen`; fires
  `PerksChanged`; `DataService.Sync`. On profile load, validate `Equipped` against `Pets` and set the attributes.
* ProximityPrompts: for each `lobbyInfo.Shop.Roulettes[id].PromptPart`, create a `ProximityPrompt` there
  (ActionText "Open", ObjectText = roulette DisplayName, HoldDuration 0, MaxActivationDistance 12,
  RequiresLineOfSight false); `Triggered` -> `OpenPanel:FireClient(player, "Shop", {Tab="Roulette", RouletteId=id})`.
  (LobbyBuilder only supplies the parts, PetService creates and connects the prompts.)

### `server/Services/ItemService.lua` (economy agent)
```lua
ItemService.Init(lobbyInfo, deps)     -- deps = { DataService=, DamageService=, MatchService= (set later by Main: ItemService.SetMatchService(ms) also allowed) }
ItemService.Buy(player, itemId, qty) -> ok, reason      -- qty 1..MaxCarry; not in match; spends tokens; respects MaxCarry
ItemService.Use(player, itemId) -> ok, reason           -- match `Playing` only (refused while the match is still in its
                                                        --   `Countdown` intro: nothing consumed, no cooldown started), alive,
                                                        --   not downed; effects above; decrements; Sync; Notify
```
Creates a `ProximityPrompt` on `lobbyInfo.Shop.ItemShop.PromptPart` -> `OpenPanel(player, "Shop", {Tab="Items"})`.
Remotes `BuyItem` / `UseItem` are connected here (rate-limited, validated).

## 3. Spots (world agent: `SpotService`)
```lua
SpotService.Init(lobbyInfo, deps)         -- deps = { DataService=, PetService= }
SpotService.GetSpot(player) -> SpotInfo|nil
SpotService.Teleport(player)              -- pivot to the spot's SpawnCFrame (ignored when InMatch)
```
* On join (after profile load) assign the player's preferred `Profile.SpotIndex` if free, else the lowest free spot;
  set attribute `SpotIndex`; store it in the profile. Free the spot on leave. No free spot -> no spot (all
  spot features simply skip that player).
* Update the spot's nameplate: `NameLabel.Text = DisplayName`, `SubLabel.Text` e.g. `"3 pets • 120 ☁"` (refresh when
  the profile/pets/tokens change; unowned spots read `"Free spot"` / `"Step in to claim"`).
* **Showcase podium**: on the spot's podium show a slowly rotating (+ bobbing) `PetBuilder.Build` of the owner's
  best (highest rarity) equipped-or-owned pet, scale 1.4, with a small name/rarity billboard (Theme fonts).
  Rebuild only when that pet changes. Everything parented under `SpotInfo.Folder`. The pet is ONE welded assembly in a
  static rest pose (only its PrimaryPart is Anchored, every other part is unanchored and welded to it, no
  `PetBuilder.Animate`), so a spin/bob step is a single CFrame write; the server moves it at 10 Hz and only while a
  player is within **55 studs** of the podium (section 12).
* `Remotes.GoToSpot` -> `Teleport` (rate-limited; refuses InMatch).
* New characters spawn in the lobby at `PlayerService.GetLobbySpawnCFrame()` unless they own a spot, in which case
  `PlayerService` asks `SpotService` via the spawn provider chain: first spawn -> plaza, later respawns in the lobby ->
  the owner's spot. (World agent decides; keep it simple: respawn at own spot when it exists.)

## 4. Lobby v2 (lobby agent: `LobbyBuilder`)
Much **bigger** (`Config.Lobby`: plaza radius 110, portals ring 88, spots ring 215, shop island at `ShopOffset`),
calm and pretty with the dimmer palette (see section 6). Contents: grand plaza with a rainbow-ish arch (muted
colours), five portal gates (Easy->Saint, each in its `Difficulty.Color`, with star count), a **shop island** with
four roulette machines and an item-shop counter, **16 spot islands** on the outer ring, floating decor islands,
bridges/steps between islands (every area reachable on foot, with no jumps harder than a simple jump; players must
never be able to get stuck), ambient fireflies/sparkles, a how-to-play board, welcome sign. < ~2500 parts total,
mostly Anchored, small parts `CastShadow = false`. Everything under `workspace.NimbusLobby`.
```lua
LobbyBuilder.Build() -> LobbyInfo
LobbyInfo = {
  Folder = Folder, SpawnCFrame = CFrame,                          -- plaza
  Portals = { Easy = PortalInfo, Medium = ..., Hard = ..., Extreme = ..., Saint = ... },   -- PortalInfo as in ARCHITECTURE.md
  Spots = { [1..Config.Lobby.SpotCount] = SpotInfo },
  Shop = {
    Roulettes = { [rouletteId] = { Id = rouletteId, PromptPart = BasePart, Center = Vector3, Model = Instance } },  -- 4 machines
    ItemShop  = { PromptPart = BasePart, Center = Vector3, Model = Instance },
  },
}
SpotInfo = { Index = n, Folder = Folder, Center = Vector3, SpawnCFrame = CFrame,   -- where the owner stands/respawns (+3 studs up)
             NameLabel = TextLabel, SubLabel = TextLabel,                           -- nameplate billboard (Theme fonts)
             PodiumCFrame = CFrame }                                                -- centre of the showcase podium top surface
```
Roulette machines: a chunky stylised machine (cabinet + glowing wheel/dome in the roulette colour + a big price
sign "50 ☁" and name via BillboardGui with Theme fonts); each has a small `PromptPart` in front. The machine colour =
`Roulette.Color`. LobbyBuilder does NOT create ProximityPrompts (PetService/ItemService do).
Billboards use `MaxDistance`, `AlwaysOnTop = false`, readable at 40+ studs.

## 5. Match / difficulties (match agent)
* Five portals; `PortalService` iterates `Config.Difficulties` (no hard-coded ids). `MatchService` uses
  `Config.Damage.VoidDamage[id]`, `Config.Match.TokenBonusOnWin[id]`. Remove every reference to old ids.
* Pet perks: `deps.PetService` is passed into `MatchService.Init`. Token pickups: `n' = n * PetService.GetTokenMultiplier(p)`
  with a per-player fractional carry so rounding is fair over time; checkpoint heal = `CheckpointHealFraction *
  (1 + perks.CheckpointHeal)`. `DataService.RecordMatch(player, id, won, seconds)` at match end (each member; Wins
  and BestTimes only for finishers on victory). `Stats.TokensEarned` increments with tokens collected.
* `MatchState` / `MatchResult` / `PartyState` payloads are unchanged (see ARCHITECTURE.md) except `DifficultyId`
  now spans the five ids and `MatchResult` adds `Stars = difficulty.Stars`.
* Players cannot use shop/spot teleports during a match; `OpenPanel` for Shop is ignored in matches.
* **Fall rule (stacked laps).** Besides the `KillY` plane, a landing more than **12 studs below the player's last
  standing height** counts as a void fall: `VoidDamage[id]` (kind `"Void"`) and a return to the team checkpoint, once.
  Details and exemptions in section 12.

## 6. Lighting + palette (world agent: `LightingService`; uikit agent: `Theme`)
The previous look was blown-out. New target: **late-afternoon calm** — readable, moody-but-friendly, high clarity.
* `Lighting.ClockTime ~ 15.2`, `Brightness ~ 1.5`, `Ambient ~ (84,96,128)`, `OutdoorAmbient ~ (108,120,152)`,
  `ExposureCompensation ~ -0.3`, `EnvironmentDiffuseScale ~ 0.5`, `EnvironmentSpecularScale ~ 0.4`,
  `GlobalShadows = true`, soft shadows (`ShadowSoftness 0.25`); Atmosphere `Density ~ 0.3`, `Offset 0.25`,
  `Color` blue-grey, `Decay` soft peach, `Glare 0.2`, `Haze 1.2`; `Bloom` Intensity ~0.12 Size ~16 Threshold ~1.8;
  `SunRays` Intensity ~0.04; `ColorCorrection` Contrast ~0.14, Saturation ~0.08, Brightness ~ -0.03, TintColor soft cool;
  keep `DepthOfField` off or extremely subtle. Never wash out whites.
* `Theme.Colors` keeps every existing key (other code depends on them) but values become calmer/darker:
  `Cloud` ~ (214,224,240), `CloudShade` ~ (150,168,200), `Storm` ~ (54,60,88), sky tones deeper, `White` stays
  (255,255,255) for text only. Add `Theme.World = { CloudTop, CloudSide, CloudShadow, Trim = {…per difficulty…},
  Hazard, HazardGlow, Checkpoint, Token }` — the in-world palette that LobbyBuilder/CourseBuilder use for parts
  (no pure white parts; platform tops clearly lighter-or-darker than the sky behind them; hazards a distinct
  saturated-but-dark red/purple; checkpoints teal/green; trims in the difficulty colour).

## 7. Course generator v2 (layoutgen agent: `CourseLayout`; coursebuild agent: `CourseBuilder`)
`CourseLayout.lua` is a **pure** module (no Instances; only Config, Util.NewRng, Vector3 math) exposing
`GenerateLayout(difficultyId, seed)` and `ValidateLayout(layout)`. The **first lines of CourseLayout.lua must contain a complete,
exact schema comment** (every Layout/Step/Hazard/Scenery/Side field, units, coordinate conventions, which `Hazard.Type` maps to
which `Config.Tags` + attributes) because the coursebuild agent codes the geometry against it. `CourseBuilder.lua` re-exports
`GenerateLayout`/`ValidateLayout` from `CourseLayout` (so the public API `CourseBuilder.GenerateLayout/ValidateLayout/Build`
is unchanged) and implements `Build`. Tag/attribute names and meanings are canonical in the `Config.Tags` comments:
the builder must set EXACTLY those attributes (converting origin-relative layout coordinates to world coordinates, e.g. a
Cannon's `Target`, a Pendulum's `Hinge`), and HazardService reads them.

Rewrite for **variety**. API unchanged (`GenerateLayout`, `ValidateLayout`, `Build`) — `CourseInfo` unchanged
except `Archetype`, `Themes` added. `GenerateLayout(difficultyId, seed)` stays **pure** (no Instances, deterministic).
* **Archetypes** (`Config.Archetypes`, chosen by the difficulty's weight table): the macro path the steps follow.
  `Straight` (climbing line, gentle lateral drift), `Zigzag` (long switchbacks left/right between stages),
  `Serpent` (sinusoidal snake), `Spiral` (helix around a central pillar/void; radius 45–75, rising each lap).
  Progression is NOT limited to +Z any more. Stage `i` ends at checkpoint `i`; the whole route climbs overall.
* **Stage themes** (`Config.StageThemes`, weights per difficulty; no two consecutive stages share a theme when more
  than one is allowed; stage 1 is always `Stones`/`Bounce`-safe; last stage may be `Gauntlet`):
  Stones, Beams (long narrow 2.5–4 stud wide beams, 14–30 long), Bounce (bounce pads to higher steps, within
  reach), Moving (sliding clouds, extremes within the gap guarantees), Spin (platform with spinning bar), Storm
  (dark rain cloud above a platform), Lightning (warned strike zones, always a safe spot), Vanish (steps that fade),
  Cannon (a `CloudCannon` pad flings you along a ballistic arc to a landing island 25–60 studs away; **landing
  verified**: target inside the landing top surface with >= 2.5 stud margin, flight time 1.0–2.2 s, peak height
  <= 60 above the pad, launch speed <= 170), Wind (gust zone over a wide platform, always ends on a platform you can
  stand on; Force <= 26 studs/s), Pendulum (swinging beam over a platform >= 9 wide), Plates (co-op plate bridge:
  as before), DashGap (gap within [DashGapMin, DashGapMax] needing a dash, with the DASH arrow sign), Gauntlet
  (short run mixing 3 hazards).
* **Golden tokens**: 1–2 per stage (more on harder levels) in risky spots, `Value = Config.Tokens.GoldenValue`
  (gold-white, bigger, tagged `Config.Tags.GoldenToken` + `CloudToken`). Regular tokens as before
  (`TokensPerStage`). Layout `TotalTokens` counts token VALUE.
* **Scenery** so courses look different: each stage gets a floating landmark matching its theme (giant ring,
  crystal spires, striped sky balloon, rainbow arc, lantern cluster, windmill of clouds...) built from parts,
  placed away from the route (never intersecting steps or blocking jumps), plus distant cloud puffs. The path
  and colours follow the dimmer palette (`Theme.World`), trim colour = difficulty colour with a per-stage tint.
* **Validation (replaces the old +Z/lateral rules)** — `ValidateLayout` must prove, for every layout:
  walkable consecutive steps: edge-to-edge gap in `[GapMin, GapMax]` (DashGap steps in
  `[DashGapMin, DashGapMax]`, which must be `<= 0.85 * MaxDashGap` and `> 0.75 * MaxRunGap`), rise in
  `[-4, min(RiseMax, 0.7 * JumpHeight)]`; cannon links per above; steps never closer than 2 studs to any
  non-adjacent step (3D box distance); **headroom**: no step's underside lies within the lower step's `Headroom`
  (>= `Config.Course.Clearance` = 13, more for decor and hazards, see section 12) above another walkable step's top surface
  where their XZ footprints overlap, and the **jump corridors** stay free (section 12); every step within
  `Config.Course.MaxRadius` (horizontal) of the origin; no step lower than `origin.Y - 10`; platform sizes in
  range (Beams/Checkpoint/Start/Finish exceptions as before: Start >= 24x24, Checkpoint >= 14x14, Finish >= 28x28);
  exactly `Stages` checkpoints, the last one followed by the Finish; every hazard step is on a platform large enough
  for its hazard (Pendulum/Wind >= 9 wide). Return all problems.
* Course for the same `(difficulty, seed)` is identical; different seeds give different archetype/theme mixes.
  Statistics (steps, tokens, archetype mix, theme mix) must differ meaningfully between difficulties.
* Build tags/attributes: as `Config.Tags` (incl. new Pendulum, WindGust, CloudCannon, GoldenToken). Keep
  < ~2500 parts per course.

## 8. Hazards (hazards agent: `HazardService`, `TokenService`)
Add: `Pendulum` (beam hinged above; rotate +/- `Arc` degrees about its hinge sinusoidally with `Period`; touching the
beam -> `Damage(p, Damage, "Pendulum", {KnockbackFrom=beam.Position, Knockback=55})`), `WindGust` (invisible volume
part; every `Interval` s show streak particles for `Warning` s, then for ~1.5 s push players inside
by adding `Direction.Unit * Force` to `AssemblyLinearVelocity` smoothly (cap total horizontal speed gain), no damage),
`CloudCannon` (touching the pad: wait 0.35 s with a squash + puff, then set the player's root velocity so a
projectile launched from the root's CURRENT position lands exactly at `Target` after `FlightTime` under
`workspace.Gravity`: `v = (T - p)/t + Vector3.new(0, g*t/2, 0)`; ignore if already launched in the last 1 s; protect
from fall/void damage for the flight; a small "poof" particle), golden tokens (`TokenService.MakeTokenPart(position,
parent, value)` makes `Value == GoldenValue` tokens golden-white, 1.5x bigger, brighter sparkles, tagged both
`GoldenToken` and `CloudToken`). Existing hazards keep working. `TokenService.Watch` stays the only collector.
Coins are spun/bobbed by the **client** (`client/Controllers/TokenFx.lua`) while `Config.Tokens.ClientAnimated` is true,
so the server replicates no per-frame token motion (section 12).
Pet perk bonuses are applied by `MatchService`, not here.

## 9. Client

### Screen layout map (IgnoreGuiInset = false everywhere; nothing in the middle)
```
 +--------------------------------------------------------------+
 | [Match/Party panel]                         [Tokens pill]    |
 |  top-left, compact                           top-right       |
 |                                              [toast stack ↓]  |  <- right edge, small, max 4
 |                                                              |
 | [Menu column]                                  [Result card]  |  <- right edge, vertically ~45%
 |  left-centre, 5 round                           (post-match,  |
 |  icon buttons                                    compact)     |
 |                                                              |
 | [HP + stamina]       [Hotbar 1-4 bottom-centre]   [Roblox    |
 |  bottom-left (raised on touch                    jump/touch  |
 |  to clear the thumbstick)                        buttons]    |
 +--------------------------------------------------------------+
```
User-opened windows (Inventory, Pets, Shop, Stats, roulette reveal) are modal-ish windows centred on screen — allowed,
because the player asked for them; closable with the red X, Esc, or the menu button again. Everything the *game*
announces (toasts, countdown, party status, results, title card, "downed" notice, checkpoint banners) is compact and
at the sides: toasts <= 250 px wide, text 14–17 px, `Accent`/`Title` role fonts with stroke; countdown is shown inside
the match panel (small, numerals pulse); the post-match result is a compact right-side card with a "Back to lobby
(Ns)" line; the title card is a small top-left banner that fades after 4 s. Vignette/damage flash on screen edges
is allowed (subtle). DisplayOrder: HUD 10, Hotbar 11, windows 20, toasts 30.

### `client/State.lua` (uikit agent)
```lua
State.Init()                   -- connects Remotes.ProfileSync, sends RequestProfile; safe to call twice
State.Get() -> snapshot        -- never nil: defaults {Tokens=0,Pets={},Equipped={},Items={},Stats={...},Perks={...}}
State.Changed                  -- Util.Signal; Fire(snapshot)
State.OwnedCount(petId) -> n   State.IsEquipped(petId) -> bool   State.EquippedCount(petId) -> n   State.ItemCount(itemId) -> n
State.Tokens() -> n            -- reads attribute CloudTokens
```

### `client/UI/CloudUI.lua` (uikit agent) — the UI kit. Chunky "cloud" look
Style: thick dark-navy outline (UIStroke 3–4 px), soft light-blue→white-ish gradient fills (calmer, not neon),
subtle inner highlight strip, small round "cloud bump" circles on the top edge of panels, rounded corners (14–18 px),
hover/press tweens (scale 1.04 / 0.96), good contrast text (Theme fonts with stroke). Green (confirm), Pink/Red
(cancel/close), Blue, Gold (premium) button styles. Everything built from Frames/TextLabels/UICorner/UIStroke/
UIGradient/UIPadding/UIListLayout/UIGridLayout — no images.
```lua
CloudUI.NewScreenGui(name, displayOrder) -> ScreenGui       -- ResetOnSpawn=false, IgnoreGuiInset=false, ZIndexBehavior Sibling, parented to PlayerGui
CloudUI.Panel(props) -> { Root = Frame, Content = Frame, TitleLabel = TextLabel|nil, Close = fn }
    -- props: Name, Size (UDim2), Position, AnchorPoint, Title (string|nil), Closable (bool), OnClose (fn), Parent, Accent (Color3|nil), Clouds (bool, default true)
CloudUI.Button(props) -> TextButton                         -- props: Text, Style ("Green"|"Pink"|"Red"|"Blue"|"Gold"), Size, Position, AnchorPoint, Callback, Parent, TextSize
CloudUI.IconButton(props) -> { Root = Frame, Button = TextButton }   -- round: Glyph (short text), Label (caption below), Color, Callback, Parent, Size, Badge(bool)
CloudUI.Bar(props) -> { Root, Fill, SetFraction(f, animate), SetText(text), SetColor(color3) }  -- props: Size, Color, Label, Parent, Height
CloudUI.Slot(props) -> { Root, Button, SetContent(info|nil), SetSelected(bool), SetCount(n), SetHotkey(text) }
    -- info = { Glyph = string|nil, Color = Color3|nil, Pet = PetDef|nil (ViewportFrame model), RarityColor = Color3|nil, Name = string|nil }
CloudUI.Tabs(props) -> { Root, Content, Add(name, builderFn) , Select(name) }              -- tab strip + content
CloudUI.Grid(parent, cellSize, padding) -> ScrollingFrame with UIGridLayout (auto canvas size)
CloudUI.PetViewport(parent, petDef, size) -> { Frame, Destroy = fn }                        -- ViewportFrame with PetBuilder model, slow spin + flap; shares ONE RenderStepped connection (CloudUI.Update loop) for all viewports; cleans up
CloudUI.Pill(text, kind, parent) -> TextLabel                                               -- kind: info|good|bad|token|rarity colour
CloudUI.Tooltip(guiObject, textFn)                                                          -- small hover/long-press tooltip (client only)
CloudUI.RarityColor(rarityId) -> Color3
```
All constructors return objects whose instances are named for debugging, and accept `Parent`. No global state
except the single shared update loop. Text uses Theme roles only.

### HUD (hud agent: `HudController`)
`HudController.Init()`; builds ScreenGui "NimbusHud" (display order 10) with: **health bar** (bottom-left, CloudUI.Bar:
heart glyph, "78 / 100", damage-trail, low-health pulse, downed state "DOWNED – wait for a teammate"), stamina bar +
dash pip under it, **token pill** top-right (☁ glyph + count, pop on increase, shows `+match tokens` while in a match),
**match panel** top-left (difficulty name in its colour, timer, checkpoint progress, token progress, compact team list,
countdown numerals pulsing inside the panel during `Phase="Countdown"`), **party panel** (same slot, lobby only, with
Leave button), **Leave match** button (compact, inside the match panel, press twice), **title card** small top-left
fading banner. Disables the default Health core gui (retrying pcall). On touch devices raise the HP bar so it
clears the thumbstick. Exposes nothing required by other modules except `Init`.

### `NotifyController` (hud agent)
`NotifyController.Init()`: **right-edge toast stack** under the token pill (max 4, 250 px, slide in from the right,
`Accent` font 15–16 px, colour by kind, auto-fade, newest on top), the **result card** on `MatchResult` (compact,
right side, VICTORY/DEFEAT in `Title` font with gradient, difficulty + stars, time, tokens, bonus, members,
"Back to lobby in Ns"), other players' dash puffs (`DashFx`). Nothing is centred on screen.

### `DamageFx` (hud agent)
As before (vignette on the screen EDGES only, subtle; camera shake; floating damage numbers above the head; "+n ☁"
pops above the head), restyled to the new palette. Keep `DamageFx.Init()`.

### Menu + inventory (menu agent: `MenuController`, `HotbarController`)
`MenuController.Init()`: ScreenGui "NimbusMenu": the **left-centre menu column** of 5 `CloudUI.IconButton`s —
Inventory (backpack glyph), Pets (paw/heart), Shop (bag), Spot (house; fires `GoToSpot`), Stats (chart) — each
opens a window (`OpenPanel` remote also opens windows). Windows (centred, `CloudUI.Panel`, Esc closes, only one at a
time, animate in with a scale tween):
* **Inventory**: tabs **Pets** and **Items**. Pets: grid of `CloudUI.Slot`s showing owned pets (viewport, rarity
  border, `xN` count, ★ equipped marker), a detail card (big spinning PetViewport, name, rarity colour, perks via
  `PetCatalog.PerkLabel`, Equip/Unequip button -> `EquipPet`/`UnequipPet`) and an "Equipped 2/3" header. Items: slots
  for each item (glyph, count, price, description).
* **Shop**: tabs **Roulettes** and **Items**. Roulettes: 4 cards (name, price in ☁, colour, a "Odds" button showing
  `PetCatalog.GetOdds`, **Spin** button -> `BuyRoulette`; disabled with a hint when tokens are short). Spin
  animation on `RouletteResult`: a horizontally scrolling strip of pet viewports (use the result `Strip`), eased stop on index 34,
  reveal card with rarity-coloured glow, "NEW!" flag, Equip button. Items: cards with Buy (+1) -> `BuyItem`.
* **Stats**: matches, wins, win rate, tokens earned, spins, best time per difficulty, pets owned/total.
* Window state is rebuilt from `State` (re-render on `State.Changed`), no stale slots, no leaks.
`HotbarController.Init()`: ScreenGui "NimbusHotbar" (display order 11): bottom-centre, 4 `CloudUI.Slot`s bound to keys
1–4 (in `ItemCatalog.List` order, slot 4 empty/locked), tap/click or key -> `UseItem`; counts from `State`; dimmed
in the lobby (items only work in matches); small cooldown flash after use; touch-friendly (min 48 px).

### `PetController` (petclient agent)
`PetController.Init()`: renders **every player's equipped pets** (attribute `EquippedPets`, csv of ids; ids unknown
to `PetCatalog` are ignored) as client-side followers in `workspace.ClientPets`: `PetBuilder.Build(def)`, positioned
each `RenderStepped` with smooth exponential easing around the owner's HumanoidRootPart in a gentle hover
formation (slots left/right/behind at 3–5 studs, 3–4 studs up, each with its own bob phase, faces the owner's
movement direction, banks into turns, flaps harder when the owner moves fast or in the air; flies a little ahead
when the owner runs; teleports to the owner when > 60 studs away or after the owner respawns); update
only on attribute/character change events, no per-frame allocation; destroyed on player leave / unequip /
character removal. Pets of other players are rendered only within 150 studs (cull far ones). The local player's pets
are always rendered. Pets are visual only (no collision). `Util.NewRng`-free; no server cost.
`MovementController`: adapt only what v2 needs — stamina regen is multiplied by `(1 + attribute PerkStaminaRegen)`;
mobile run/dash buttons must not overlap the new bottom-left HP bar (it is raised on touch) or the Roblox jump button.
`Main.client.lua`: `State.Init()` then init `MovementController`, `HudController`, `DamageFx`, `NotifyController`,
`MenuController`, `HotbarController`, `PetController`, `TokenFx` each in `pcall` + `warn`.

## 10. Icon (icon agent: `branding/`)
Create the game icon: the **Cloudy Dragon** as a cute, polished 512x512 and 1024x1024 PNG (`branding/icon-512.png`,
`branding/icon-1024.png`) from a hand-built SVG (`branding/icon.svg`) rendered with the pre-installed Chromium
(Playwright at `PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers`, executablePath `/opt/pw-browsers/chromium`; do not run
`playwright install`). Style: bright-but-not-blinding sky-gradient background with soft clouds, the dragon big and
centred (round head, small gold horns, big glossy dark-blue eyes with sparkle highlights, cloud-white and sky-blue
fluffy body, cream belly, cloud wings spread, a cloud-puff tail), a golden cloud token floating beside it, thick
dark-navy outline, glossy highlights, high contrast — must read clearly at 128x128. No text (or at most a tiny
"NIMBUS CLIMB" ribbon that stays legible at 256 px). Also add `branding/README.md` with exact steps to upload it
in Roblox Creator Hub (Creations > your experience > Basic settings / Icon > upload 512x512 PNG). View the PNG yourself
(Read tool) and iterate until it looks good; keep file sizes < 1 MB.

## 11. Tooling (later phase; tooling agent)
Update `tools/contract.json`, `tools/robloxmock.lua`, `tools/smoke_*.lua` for every new/changed module, add
scenarios: 5 difficulties x 300 seeds layout validation (stats per difficulty + archetype + theme mix), cannon
ballistics, roulette odds sum to 1 and every rollable rarity has pets, `PetCatalog.RollPet` frequency check, economy
(spend/refund/stack cap/equip limits), items, spots (assign/free/prefer previous), profile migration v1->v2,
`ProfileSync` snapshot shape, pet follower build for every pet def (part budget), CloudUI/State load, layout
rule: no text label centred on screen from the HUD/Notify controllers (assert anchors/positions are at the sides).
`README.md` documents everything (controls, spots, pets, roulettes, items, difficulties, how to rebuild the place file with Rojo).

Regression scenarios added after the review (`python3 tools/smoke.py --list` shows all; the FULL run is `python3 tools/smoke.py`,
`--quick` uses 40 layout seeds instead of 300): `fall_rule` (MatchService fall rule, `smoke_server.lua`), `data_orphans` and the
orphan case of `shutdown` (DataService orphan retention, `smoke_server.lua`), `match_locks` (items refused in the countdown, pets
locked in matches, `smoke_economy.lua`), the podium radius / welded-assembly checks in `spots`, a mock self-test for
`AutomaticSize` + `UIScale` and the phone menu-column geometry checks in `client_mobile`, and a self-test of the Neon palette
audit (a thin neon rod is not a slab), `client_tokens` (TokenFx spin/bob rates, culling, release of collected coins,
`smoke_client_v2.lua`) and, in `hazards`, the TokenService no-animation rule for `Config.Tokens.ClientAnimated`. The Roblox mock applies a `UIScale` once (a 304 px column at scale 0.72 is 219 px tall,
not 158), moves welded parts with their root, and `Mock.SetViewport` notifies every ScreenGui like a real resize.

## 12. Behaviour changes from the review (these supersede earlier text)

* **MatchService fall rule.** Laps of Spiral/overlapping courses are stacked 15-40 studs apart, so a missed jump lands on a
  LOWER lap long before `KillY` and strands the player. Every 0.25 s poll remembers each member's last *standing* height
  (grounded = `Humanoid.FloorMaterial` or a 6 stud ray down) and whether the player has been in the air since. Touching
  ground again **more than 12 studs below that height** (`FALL_DROP = 12`) is a fall: `VoidDamage[id]` as `"Void"` (ignores
  i-frames), 1.5 s of protection and a teleport to the team checkpoint (Start while `Checkpoint == 0`), exactly once.
  Never judged: mid-air (only a settled landing is), ground-to-ground position jumps with no poll moving down in the air
  between them (teleport, respawn, lag), a poll that catches the player falling faster than 30 studs/s, hops under 12 studs
  (stairs down; cannon landings are <= 3-4 below their pad), bounce/cannon/dash flights, downed or finished players. The
  reference is the player's OWN last standing height, not the team checkpoint (stragglers on the previous stage are 15+ studs
  below it). `teleportTo` and a new character clear the memory. In `Ended` state the same landing is rescued for free (no
  damage). The 12 comes from the layout rules: honest links drop <= 4, while a step stacked above another keeps its
  underside >= `Clearance` (13) above the lower one's top, so any lower lap is more than 12 studs below.
* **Course headroom and jump corridors (`CourseLayout`).** `Config.Course.Clearance` is **13** (a full jump needs
  `JumpHeight` 6.9 + the character's ~5.2 of free air). Every step carries `Headroom` = the free height above `Pos.Y` that
  nothing of another step may enter where footprints overlap, and the maximum height of its own hazard/decor geometry:
  `max(Clearance, decor or hazard height)`. Decor: **Start and Finish 18** (arches: StartBeam top 15.9, bunting 17.0, FinishBeam
  top 17.8), **Checkpoint 10.5** (flag pole + orb 9.9, so effectively 13). The **jump-corridor rule**: for every Walk/Dash link
  the strip a jump flies through (the last 4 studs of the take-off step, the gap, the first 3 studs of the landing step,
  4 studs wide) has no OTHER solid within 1 stud of it whose underside is lower than `Clearance + 0.3` above the take-off
  step's top. `ValidateLayout` reports a violation as `"<tag> <n> hangs only X studs above the jump from step a to step b"`.
* **Tokens are animated by the client.** `Config.Tokens.ClientAnimated = true`: `client/Controllers/TokenFx.lua` spins and
  bobs every `CloudToken` part within 140 studs of the camera; the server (`TokenService`) leaves coins still and runs no
  Heartbeat driver, so no per-frame token CFrames replicate. The server still owns the pickup (the `Collected` attribute and
  the burst); TokenFx lets go of a coin once `Collected` is set. With the flag false the old server-side driver (poses only
  the coins next to a player, 15 Hz) is used instead.
* **SpotService podium.** The showcase pet is a single welded assembly: its PrimaryPart is the only Anchored part, every other
  part is unanchored with a `Weld` to it, and the pet keeps its static rest pose (`PetBuilder.Animate` is not used: it would
  write every part and cannot drive a welded assembly). A spin/bob step is one CFrame write on the root, at most 10 per
  second, and only for showcases with a player within a **55 stud** radius (it used to animate every part within ~120).
* **DataService orphan retention.** See section 1: a profile that could not be saved when its player left stays in memory as
  an orphan (a rejoin gets it back; a 10 s to 120 s backoff retry, the autosave sweep and `BindToClose` flush it; it is
  dropped after a successful write or after 30 minutes). A session whose load failed is merged on top of the stored
  profile, never over it.
* **Pets are locked during matches.** `PetService.Equip/Unequip` return `false, "Pets are locked during a match"` while
  `InMatch` is true (the countdown included) and work again afterwards (roulettes were already refused in matches).
* **Items are refused during the countdown.** `ItemService.Use` requires `match.State == "Playing"`: during `Countdown` it
  returns `false, "Wait for the countdown to finish"` without consuming the item or starting the use cooldown (the intro
  freeze already grants invulnerability, so a shield or heal used then would be wasted).
