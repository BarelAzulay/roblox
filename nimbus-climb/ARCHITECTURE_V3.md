# Nimbus Climb — v3 contract (multi-concept game: tycoon + pet battles + obby)

Read `ARCHITECTURE.md`, then `ARCHITECTURE_V2.md`, then this file. **v3 supersedes both wherever they disagree.**
`src/shared/Config.lua` already has the v3 additions (Attr.Cash/Gems, remotes TutorialState/TutorialEvent/IndexClaim,
the Secret rarity, Config.Index, Config.Tutorial, Config.PetStats, Lobby.SpotRingRadius 300 + Lobby.PlotSize 72).
`Main.server.lua` already loads and inits `IndexService`, `NpcService`, `TutorialService`; `Main.client.lua` already
loads `SkyDragonController`, `IndexController`, `NpcController`, `TutorialController` (missing modules are skipped).

## What the player asked for after the first real playtest

1. Ground looks flat and plain: make it detailed (real materials, paths, patches, grass).
2. Token aura stays behind while the coin spins/bobs: it must move with the coin.
3. More colour in the world; a slightly brighter, warmer sun so the world does not look sad.
4. An animated flying **Sage Dragon** in the sky for atmosphere.
5. A **tutorial guide**: Nimbus the Cloudy Dragon in a small side panel guides a new player step by step with a
   guiding arrow until they know the basics.
6. **NPC pets** in the lobby, each telling the player something useful (how to get more coins, more pets, ...).
7. Pets and objects look too simple: clouds do not look like clouds; pet eyes look stuck on, not part of the face.
   Make everything cleaner and more detailed.
8. A **Pet Index** of all pets (reference: a "Pet Index" window with ??? silhouettes, group progress "0/8",
   a detail card, group rewards with a CLAIM button and "Unlocked: x/N").
9. Upgrade the UI look on the menu and the HUD (not too big, not too small); **text is too small**: fix readability.
10. Make it a **multi-concept game**: obby (side mode, not the main fun), **Tycoon** (main focus, with prestige), and
    **Pet Battles** (arena + PvP; feed pets, upgrade home, pets get stronger; each pet has a special attack with
    animations and effects). Decisions: tycoon = home + pet upgrades (rooms like kitchen/gym/garden); some pets are
    better for the economy (home grind) and some for combat, usefulness scales with rarity; battles = auto-battle with
    a special-attack button; currencies = **Cash** (tycoon), **Cloud Tokens** (obby + battles, roulettes/items),
    **Gems** (Robux; buy roulettes cheaply in gems, and a gems-only **Secret** roulette). All art is built in code.

## ART DIRECTION (decided by the player after the plan): DETAILED voxel style everywhere
**This section overrides sections 6, 7 and 8 wherever they mention smooth terrain, round parts or Ball shapes.**
The player chose a voxel ("pixel") look for the whole game, and then clarified with a reference image: **NOT chunky /
low-resolution blocks**, but the **detailed, fine-voxel MagicaVoxel style**: small voxels relative to the model
(pets ~24-32 voxels tall), natural readable proportions, smooth-looking curves (curled horns, rounded heads, tapered
legs), 2-3 shades per colour region for depth (lighter on top, darker underneath and in creases), fur patterns
(stripes, spots, masks, bellies), carved eye sockets with a dark iris, a white highlight voxel and darker brows/lids,
fine details (claws, beaks, nostrils, inner ears, feather/fur tufts). Cute and appealing (these are pets), but crafted.

* **`shared/Voxel.lua` (new, owned by the pets agent)** — the voxel kit everyone uses. It SCULPTS models from signed
  distance shapes instead of hand-typed voxels:
  ```lua
  Voxel.NewGrid(resolution)               -- e.g. 32 voxels per model height; grid keys are integer voxel coords
  Voxel.Shape(grid, shape)                -- shape = { Kind = "Ellipsoid"|"Capsule"|"Box"|"RoundBox"|"Cone"|"Torus"|"Curve",
                                          --   ...geometry in voxel units..., Key = paletteKey, Op = "Add"|"Carve"|"Paint",
                                          --   Rotation = CFrame (optional), Pattern = optional fn(x,y,z)->paletteKey }
  Voxel.Shade(grid, opts)                 -- assigns shade variants per voxel: <key>_Light on exposed tops, <key>_Dark
                                          --   on undersides/creases (ambient-occlusion-like), deterministic
  Voxel.Build(grid, opts) -> Model        -- opts: { VoxelSize = studs, Palette = {key -> Color3 | {Color, Material, Transparency}},
                                          --   Anchored = true, Name, PrimaryKey, MaxParts = n }; 3D greedy merge of same-colour
                                          --   voxels into box Parts; if over MaxParts, merges nearly-equal shades first (LOD)
  Voxel.Merge(grid) -> boxes              -- the greedy merge used by Build
  Voxel.Box(parent, cframe, size, color, material, props) -> Part   -- single block helper for world building
  ```
  Shade variants: Palette may define `Fur`, `Fur_Light`, `Fur_Dark`; when a variant is missing, derive it from the base
  colour (lighter/darker by ~10-15%). Parts: `Anchored`, `CanCollide/CanTouch/CanQuery` false unless asked,
  `CastShadow` false for small parts, SmoothPlastic unless the palette says otherwise.
* **Pets (PetBuilder, pets agent):** every species sculpted in this detailed voxel style (Cat, Dog, Fox, Bunny, Bear,
  Panda, Dragon, Owl, Slime, Unicorn, Phoenix, Frog, Penguin, Axolotl), palettes from `Look` with shading and
  species patterns, accessories and wings (per WingStyle) sculpted too; wings grouped for flapping. **Two levels of
  detail:** `PetBuilder.Build(def, {Detail = "High"|"Low", Scale})`: High (default) for ViewportFrames (Index, menu),
  podiums and NPCs, <= ~350 parts; Low for follower pets of other players / far away, <= ~120 parts.
  `PetController` uses High for the local player's pets and Low for others (the petcontroller code is in client/
  Controllers/PetController.lua: the pets agent may make this one-line LOD change there). Same public API otherwise
  (`Build/Animate/GetHeight`, `WingL/WingR`, Animate from the PrimaryPart, works in ViewportFrames). Build results are
  cached per (petId, detail) on the client and cloned, so opening the Index stays fast.
* **Tokens:** a detailed voxel coin (round silhouette at fine resolution, gold with lighter rim and a cloud emblem in
  relief) and a soft halo that moves with the coin; golden tokens bigger/brighter.
* **World (world agent):** NO smooth terrain. Cloud islands = sculpted voxel clouds (puffy, soft, several shades of
  white/very light blue, bigger voxels than pets, e.g. 2-3 studs, so part counts stay sane); ground = tiles with subtle
  colour variation and clear stone/sand/wood paths; detailed voxel trees (sculpted canopies with shading), lamps,
  benches, fences, banners, fountains (translucent blue water blocks), flower clusters; portals, roulette machines,
  shop and home plots in the same crafted style. Cheerful colours, not blinding. Whole lobby <= ~6000 parts after
  merging; build heavy decor once and reuse by `:Clone()`.
* **Sky Dragon (skydragon agent):** a detailed voxel eastern Sage Dragon sculpted with the kit (segments, head with
  horns/whiskers/mane), <= ~300 parts.
* **NPC pets** use PetBuilder High detail at Scale ~2.2 on crafted voxel pedestals.
* **UI** stays the chunky cloud UI (2D).

## Phases
* **Phase 1 (this build):** items 1–9 + the data foundations phases 2/3 need (pet roles/stats/specials, secret pets,
  bigger home plots in the lobby).
* **Phase 2:** tycoon homes on the plots, Cash, rooms, economy pets working at home, prestige, Gems + developer
  products + gem/secret roulettes.
* **Phase 3:** battle arena, PvE ladder + PvP, feeding/levels, specials with animations.

## Global rules (additions)
* Everything from the earlier docs still applies (Lua 5.1 syntax, Theme fonts only, no asset ids, server-authoritative,
  rate-limited validated remotes, nothing system-announced in the screen centre).
* **Replication rule:** anything that moves every frame and is purely visual (sky dragon, NPC idle bobbing, token
  spin, pet followers) is animated on the **client**. The server never rewrites part CFrames at high frequency.
* **Readability rule:** at a 1920x1080 screen, body text >= 18 px, small captions >= 15 px, buttons >= 20 px, titles
  28–44 px; everything scales with screen height (factor clamp(viewportY / 1080, 0.8, 1.25)) and phones never go
  below 14 px. Every text has a stroke or sits on a solid panel so it reads on any background.
* **World text rule (added after the player's playtest: "letters too small, when you zoom a little you can barely
  read it"):** text in the 3D world must stay readable from normal camera distances. Name/info tags above things
  (BillboardGui) are sized in PIXELS (offset UDim2, never studs-scale for text), so they keep a constant on-screen size:
  names >= 22 px and info lines >= 18 px at 1080p, with a dark stroke, a compact solid backing plate sized to the text
  (no huge empty panels), sensible MaxDistance (~60-120 studs) and LightInfluence 0. Big signs on surfaces (SurfaceGui)
  use PixelsPerStud ~40-60 and letters at least ~1 stud tall for titles and ~0.6 stud for info lines, so they read
  from ~30 studs. Never a fixed small TextSize inside a studs-sized billboard. Every new sign follows this.
* **Terrain** (`workspace.Terrain`, smooth terrain) may be used for organic shapes (cloud islands, ground). Use
  `Terrain:SetMaterialColor` to tint materials. Terrain is static: build it once at boot.

## Ownership (phase 1)
| Agent | Files |
|---|---|
| world | `server/Services/LobbyBuilder.lua`, `server/Services/LightingService.lua` |
| skydragon | `client/Controllers/SkyDragonController.lua` (new) |
| pets | `shared/Voxel.lua` (new), `shared/PetBuilder.lua`, `client/Controllers/TokenFx.lua`, `server/Services/TokenService.lua` |
| catalog | `shared/PetCatalog.lua`, `server/Services/DataService.lua`, `server/Services/PetService.lua`, `server/Services/IndexService.lua` (new) |
| ui | `shared/Theme.lua`, `client/UI/CloudUI.lua`, `client/Controllers/HudController.lua`, `client/Controllers/NotifyController.lua`, `client/Controllers/DamageFx.lua` |
| menu | `client/Controllers/MenuController.lua`, `client/Controllers/HotbarController.lua`, `client/Controllers/IndexController.lua` (new), `client/State.lua` |
| tutorial | `shared/TutorialSteps.lua` (new), `server/Services/TutorialService.lua` (new), `client/Controllers/TutorialController.lua` (new) |
| npc | `shared/NpcDialog.lua` (new), `server/Services/NpcService.lua` (new), `client/Controllers/NpcController.lua` (new) |
| lead / tooling | `shared/Config.lua`, `Main.*.lua`, docs, `tools/*` |

---

## 1. Data (catalog agent: DataService)
Profile gains (migrate older profiles; defaults shown):
```lua
Discovered = { [petId] = true },   -- every pet ever owned/rolled (owned pets at migration time count as discovered)
IndexClaimed = { [groupId] = true },
Tutorial = { Step = 1, Done = false, Gifted = false },  -- Step = index into TutorialSteps.Steps
-- reserved for phase 2/3 (create with defaults now so later phases do not need another migration):
Cash = 0, Gems = 0, Home = { Level = 0, Rooms = {}, Prestige = 0 }, PetLevels = {},  -- PetLevels[petId] = {Level=1, Xp=0}
```
`ProfileSync` snapshot gains `Discovered`, `IndexClaimed`, `Tutorial` (plain tables). Do NOT show Cash/Gems in the
HUD until phase 2 sets the attributes.
New DataService helpers: `DataService.MarkDiscovered(player, petId) -> isNew`, `DataService.GetTutorial(player)`,
`DataService.SetTutorial(player, tutorialTable)` (MarkDirty + Sync).

## 2. Pet catalog v3 (catalog agent: PetCatalog)
Every PetDef gains (keep all existing fields; ids unchanged):
```lua
Role = "Economy" | "Combat",
Stats = { Income = n, Power = n, Health = n, Speed = n },   -- BASE values at rarity scale 1 (multiplied by Config.PetStats.RarityScale[rarity])
Special = { Id = "snow_burst", Name = "Snow Burst", Kind = "Blast"|"Heal"|"Shield"|"Storm"|"Pounce"|"Freeze"|"Beam", Power = n, Color = Color3 },
```
Economy pets: high Income, low Power/Health; Combat pets: the opposite. Roughly half of each per rarity. The Cloudy
Dragon is Combat (signature special "Cloud Breath", Kind "Beam").
Add **3 Secret pets** (Rarity "Secret", Glow = true, dark/iridescent palettes, only obtainable later from the
gems-only Secret roulette; they are NOT in any current roulette's possible list). Use existing species + accessories.
New pure helpers:
```lua
PetCatalog.IndexGroups() -> { {Id = rarityId, Rarity = rarityId, Pets = {PetDef...}, Reward = Config.Index.Rewards[rarityId]}, ... }  -- in rarity order, Secret last
PetCatalog.GetStats(petId, level) -> {Income, Power, Health, Speed}   -- base * RarityScale * (1 + 0.1 * (level - 1))
PetCatalog.TotalCount() -> n
```

## 3. Pet Index (catalog agent: IndexService + PetService; menu agent: IndexController)
* `PetService`: after a successful roll call `DataService.MarkDiscovered(player, petId)`; the RouletteResult `IsNew`
  keeps meaning "first time owned".
* `IndexService.Init(deps)` (deps: DataService, PetService); `IndexService.CanClaim(player, groupId) -> bool, reason`;
  `IndexService.Claim(player, groupId) -> ok, reason` (group complete = every pet in that group discovered; once
  only; grants the Config.Index reward via DataService.AddTokens; Notify the player; Sync). Remote `IndexClaim`
  (rate-limited, validated). `IndexService.Completed` signal Fire(player, groupId) (the tutorial may listen).
* `IndexController` (client): `IndexController.Init()`, `IndexController.Open(groupId|nil)`, `IndexController.Close()`.
  Opens on the menu "Index" button and on `OpenPanel("Index")`. Layout (like the reference, cloud-styled through
  CloudUI): title bar "Pet Index" + red X; left: vertical group list (one tile per rarity group: rarity-coloured
  gradient art tile, group name, "3/6" progress); centre: grid of pet tiles (ViewportFrame of the pet; undiscovered
  pets are black silhouettes using `ViewportFrame.ImageColor3 = Color3.new(0,0,0)` with a "???" caption; discovered
  show name); a group progress bar "x/N"; right: detail card (big viewport, name or "???", rarity, Role, stats and
  special name when discovered); rewards box ("Rewards:" with the token amount) and a CLAIM button (green when
  claimable, grey otherwise, "Claimed" when done) -> `IndexClaim`; footer "Unlocked: x/N" over all pets.
  Viewports are built a few per frame (as MenuController does), silhouettes never animate, one shared update loop.

## 4. Tutorial (tutorial agent)
`shared/TutorialSteps.lua` (data only):
```lua
TutorialSteps.Steps = {
  { Id = "welcome",   Text = "...", Target = nil,                       CompleteOn = "Next" },          -- player presses Next
  { Id = "home",      Text = "...", Target = { Kind = "Spot" },          CompleteOn = "NearSpot" },      -- within 14 studs of own SpotInfo.Center
  { Id = "shop",      Text = "...", Target = { Kind = "Shop" },          CompleteOn = "ShopOpened" },    -- client TutorialEvent
  { Id = "spin",      Text = "...", Target = { Kind = "Roulette", Id = "Cloud" }, CompleteOn = "Rolled", Gift = true },
  { Id = "equip",     Text = "...", Target = { Kind = "Menu", Id = "Pets" },      CompleteOn = "Equipped" },
  { Id = "index",     Text = "...", Target = { Kind = "Menu", Id = "Index" },     CompleteOn = "IndexOpened" },
  { Id = "portal",    Text = "...", Target = { Kind = "Portal", Id = "Easy" },    CompleteOn = "MatchStarted" },
  { Id = "finish",    Text = "...", Target = nil,                       CompleteOn = "MatchEnded" },
  { Id = "done",      Text = "...", Target = nil,                       CompleteOn = "Next" },
}
```
(Write friendly, short texts in Nimbus' voice; phases 2/3 will append steps for the home and the arena.)
* `TutorialService.Init(lobbyInfo, deps)`: tracks each player's step (from the profile; players that joined before
  Init too), advances on server-observed events (NearSpot poll ~2 Hz using SpotService.GetSpot; Rolled via
  PetService roll -> listen to the RouletteResult path: expose/consume a PetService signal `Rolled` (add it in
  PetService if missing — coordinate: the catalog agent adds `PetService.Rolled` Util.Signal Fire(player, petId));
  Equipped via `PetService.PerksChanged` or profile Equipped non-empty; MatchStarted/MatchEnded from
  `MatchService` (use player attribute InMatch true/false transitions); client events via remote `TutorialEvent`
  ("Next", "ShopOpened", "IndexOpened", "Skip") validated against the CURRENT step only. The "spin" step grants
  `Config.Tutorial.GiftTokens` once (Tutorial.Gifted). Finishing grants `Config.Tutorial.FinishReward`. "Skip" ends the
  tutorial (Done = true). Persists via DataService.SetTutorial. Fires `TutorialState` to the player:
  `{ Step = n, Total = #Steps, Id = step.Id, Text = step.Text, Target = step.Target, Done = bool }` on join, on change.
* `TutorialController.Init()`: a compact side panel (left side, below the top-left panel area, never centred):
  a small round portrait of Nimbus (PetBuilder Cloudy Dragon in a ViewportFrame, gently flapping), the step text
  (typewriter reveal, readable size), "Step 3/9", a Next button when CompleteOn = "Next", and a small Skip link
  (asks to confirm). **Guide arrow**: for world targets (Spot, Shop/Roulette machine, Portal) show a 3D bouncing
  arrow above the target plus a dotted Beam trail from the player's HumanoidRootPart toward it (client-side parts in
  workspace.ClientFx); for Menu targets highlight the menu button (pulsing ring around the `MenuButton_<Id>` button
  created by MenuController) and point a small on-screen arrow at it. Fire `TutorialEvent("ShopOpened")` when the
  Shop window opens and `"IndexOpened"` when the Index opens (MenuController/IndexController expose
  `MenuController.WindowOpened` Util.Signal Fire(windowId) — the menu agent adds it). Hidden while in a match except
  the "finish" step text. Celebrate completion with a small confetti burst at the side panel.
* World target positions come from the workspace: Spot = own spot (attribute SpotIndex -> workspace.NimbusLobby
  spot folder with attribute SpotIndex), Shop/Roulette = the roulette machine model (LobbyBuilder names it
  `Roulette_<Id>`), Portal = `Portal_<Id>` model. LobbyBuilder must keep those names (world agent).

## 5. NPC pets (npc agent)
* `shared/NpcDialog.lua`: 6 NPCs: `{ Id, Name, PetId (an existing catalog pet for the look), Scale = 2.2, Lines = {..} }`
  e.g. "Coach Corgi" (how to earn more tokens: harder portals pay more, golden tokens, win bonus),
  "Granny Owl" (pets: roulettes, rarity, odds, Index rewards), "Mayor Panda" (your home spot; the tycoon is coming),
  "Captain Penguin" (co-op tips: revive teammates at checkpoints, Phoenix Feather), "Sparky Fox" (controls: run, dash,
  items 1-4), "Nimbus" is NOT an NPC (it is the tutorial guide). 3-5 short lines each.
* `NpcService.Init(lobbyInfo, deps)`: builds each NPC with `PetBuilder.Build` at `lobbyInfo.NpcSpots[i]` (world agent
  supplies 6 CFrames on the plaza/paths, facing the walkway), a small pedestal/rug, a nameplate billboard (Theme
  fonts, readable) and a `ProximityPrompt` (ActionText "Talk", ObjectText = Name, HoldDuration 0, distance 10).
  Tag each NPC model `NC_Npc` with attribute `NpcId`. Server never animates them.
* `NpcController.Init()`: idles every `NC_Npc` model locally (gentle bob + slow turn toward the nearest player +
  PetBuilder.Animate wing flaps at low frequency) and shows the dialog when the local player triggers the prompt
  (`ProximityPromptService.PromptTriggered` on the client): a side dialog box (bottom-left above the HUD, NOT centred)
  with the NPC's name, a small portrait viewport, typewriter text, Next / Close; cycles through Lines.

## 6. World (world agent: LobbyBuilder + LightingService)
* **Clouds that look like clouds:** build the cloud islands from **smooth terrain** (many overlapping `FillBall`s of
  material Snow tinted soft cloud white/blue with `SetMaterialColor`, plus Glacier/Salt accents) so they are soft and
  organic; keep part-built decor on top. Add `workspace.Terrain` child `Clouds` (Cover ~0.5, Density ~0.6, soft colour)
  for real moving sky clouds.
* **Detailed ground:** plaza and walkways get real materials and structure: terrain Grass (with `Terrain.Decoration =
  true` for grass blades) for lawns, Cobblestone/Pavement/Brick paths with borders, wooden boardwalks (WoodPlanks),
  sand patches, flower beds, hedges, rocks, trees (several shapes), lamp posts, banners/bunting in the difficulty
  colours, fountains. Use part materials (Grass, Cobblestone, Brick, WoodPlanks, Slate, Sand, Fabric) — no more flat
  SmoothPlastic everywhere.
* **More colour:** flowers, banners, roofs, awnings, coloured stones; still calm, not neon-blinding.
* **Home plots (phase-2 ready):** the 16 spots become larger home plots on `Config.Lobby.SpotRingRadius` with a flat
  `Config.Lobby.PlotSize`-square grass yard (fence posts, a gate facing the ring road, a mailbox nameplate, the pet
  podium) — the yard centre stays EMPTY and flat for the phase-2 home. Keep `SpotInfo` fields and add
  `SpotInfo.PlotCFrame` (centre of the flat yard surface, facing the gate) and `SpotInfo.PlotSize`.
* Keep `LobbyInfo` (Portals, Spots, Shop) and add `LobbyInfo.NpcSpots = { CFrame, ... }` (6). Keep names
  `Portal_<Id>` and `Roulette_<Id>` for the portal and roulette models (tutorial targets). Everything stays walkable
  (ramps/bridges/paths; no traps), within performance budget (parts < ~3500; terrain is cheap).
* `LightingService`: slightly brighter and warmer — ClockTime ~14.5, Brightness ~2.0, a warmer ColorShift_Top,
  OutdoorAmbient a little higher, Bloom stays subtle; keep it readable (no blow-out). Keep Technology from the
  project file.

## 7. Sky Dragon (skydragon agent)
`SkyDragonController.Init()`: a large **Sage Dragon** (eastern/serpentine: sage-green scales, cream belly, gold horns
and whiskers, a flowing mane, fins along the spine, a cloud-tuft tail tip) built client-side in `workspace.ClientFx`
from ~24 body segments that follow the head along a smooth closed 3D path (e.g. a slow figure-eight / Lissajous loop
120–240 studs above and around the lobby, period ~70 s), undulating; head with glowing eyes, horns, whiskers that
trail; soft cloud-puff particles trailing. No collisions, no shadows, CanQuery/CanTouch false. One RenderStepped
loop, no per-frame allocation, frozen when far from the lobby (player in a match far away). Max ~180 parts.

## 8. Pets & tokens polish (pets agent)
* **Eyes:** eyes must look set INTO the face: the eye ball's centre sits inside the head so only a lens-shaped front
  shows; pupil and highlight sit exactly on the eye surface (no floating dots); eyelids/lash line optional; cheeks
  flush. Cleaner silhouettes for every species (smooth joins, ears that meet the head, consistent proportions),
  fluffier cloud wings for the Cloudy Dragon. Keep API, part budget <= ~70, Animate contract.
* **Token aura:** the aura/halo must move with the coin. TokenFx animates the whole token (coin + halo) — the halo
  bobs with the coin (it need not spin). TokenService builds it so the client can find it (e.g. a child named
  `Halo` of the token root, or tag it); keep `Config.Tokens.ClientAnimated = true`.

## 9. UI (ui agent + menu agent)
* `Theme`: readability rule above; add `Theme.ScaledSize(basePx)` (uses the screen-height factor) and raise every
  role's default size; text stroke on light backgrounds; keep all existing keys/functions.
* `CloudUI`: a more polished chunky style like the reference (thick dark outline, glossy top strip, bold title bar
  with big title text, red X button, consistent paddings), all sizes via the readability rule. API compatible.
* `HudController`: bigger, cleaner HUD; a **currency stack** at the bottom-left above the HP bar showing Cloud Tokens
  now (big number with K/M abbreviations and the cloud glyph) and ready to show Cash and Gems when those attributes
  exist (phase 2); everything else per the layout map, sized by the rule.
* `MenuController`: the left menu becomes the reference style: square-ish rounded icon tiles with the big glyph and a
  bold label under each (Inventory, Pets, Index, Shop, My Spot, Stats), named `MenuButton_<Id>`; expose
  `MenuController.WindowOpened` (Util.Signal, Fire(windowId) whenever a window opens) and handle
  `OpenPanel("Index")` by calling `IndexController.Open`. Windows sized by the rule (not too big, not too small).
* `HotbarController`, `NotifyController`, `DamageFx`: readable sizes per the rule.

---

## 10. The player's own creature: Stormfang + the Storm Altar (added after the player shared their art)
The player designed this creature themselves and wants it in the game. Reference art (READ these images before
building): `branding/stormfang-concept.webp` (original sheet: three poses of the creature on dark storm clouds plus a
crystal altar ring), `branding/stormfang-art.png` (same, transparent background) and `branding/stormfang-portrait.png`
(close-up of the head). The player uploaded the sheet to Roblox as asset 129423539279679 -> `Config.Art.StormfangImage`.

* **Pet (catalog agent + pets agent):** `Id = "stormfang"`, `Name = "Stormfang"`, `Rarity = "Secret"` (the 4th Secret pet,
  listed first among the Secrets: it is the player's signature creature), `Role = "Combat"`, Special "Storm Pounce"
  (kind `Pounce`, electric blue), stats/perks at the top of the Secret tier (must pass the Secret > best Mythic check).
  New species `"Stormfang"` (added to `PetCatalog.Species` and built by PetBuilder, NOT a recoloured Fox/Cat).
  Look, faithful to the art in the detailed voxel style: a lean, fierce but cute storm lynx; body of layered charcoal
  armour plates (3-4 greys: ~#2a2c33 base, #4b4d57, #70737e, light bevelled edges ~#a3a6ae) with ridge spikes sweeping
  back over the head, shoulders and spine; a white fluffy face mask and cheek ruff (white/very light grey shading);
  tall pointed lynx ears with NEON violet (~#7a3cff) and electric-blue (~#2fb4ff) inner stripes; fierce glowing blue
  eyes with a violet rim (Neon); a cyan diamond gem (~#3fc8ff, Neon core + Glass rim) on the forehead and smaller
  gems on the shoulder and chest plates; big armoured paws with glowing cyan claws (Neon); a fluffy armoured tail
  with neon stripes. Instead of feathered wings it rides a small dark storm cloud (navy #2e3a66 / #44507f / lighter
  #6b77a8 tops with a few white puffs): `WingStyle = "StormCloud"` (new style, added to `PetCatalog.WingStyles`;
  PetBuilder still returns the cloud halves as WingL/WingR so Animate can sway them gently). Animate: hover, the
  cloud drifts, neon parts pulse softly (client only). Budgets: High <= ~350 parts, Low <= ~120.
* **Storm Altar (world agent, lobby landmark), from the ring in the art:** a dark navy storm-cloud island (contrast
  landmark among the white clouds) at the lobby edge, facing the plaza, with a circular dais: a ring of charcoal stone
  blocks (radius ~12 studs) with bevelled tops, 6-8 tall cyan crystal shards (Neon core + Glass) around it (the front
  one biggest), a dark navy portal disc in the middle with a faint glow, and soft electric-blue PointLights.
  A big Stormfang showcase (PetBuilder High, Scale ~3, named `StormfangShowcase`) prowls on the altar; the NPC
  controller-style client animation (hover/pulse) applies to it. A poster/billboard `StormAltarSign` shows
  "STORM ALTAR" and the art (`Config.Art.StormfangImage`). ProximityPrompt "Storm Altar": Phase 1 -> side toast
  "The Storm Altar awakens soon: summon Secret pets with Gems!"; Phase 2 turns it into the gems-only Secret roulette.
  Model name `StormAltar`, part budget <= ~450 (excluding the showcase pet).
* **Pet Index (menu agent):** Stormfang's card is a ??? silhouette until discovered, like every pet; once discovered,
  its detail view also shows the 2D art (`Config.Art.StormfangImage`) as a banner.
* **Tutorial/NPCs:** one NPC tip mentions the Storm Altar and Secret pets.

## 11. Elements, battle teams and the Fusion Machine (asked for by the player during the build)
**Elements (build now, with the Stormfang round):** every pet gets one `Element` besides its rarity. Eight elements
(`Config.Elements`), fitting the sky/cloud world, from the player's list (lightning + wind -> Storm, dark/demonic ->
Shadow, light/angelic -> Celestial) plus Frost for the icy pets:
```
Wheel (each beats the next):  Water > Flame > Frost > Nature > Earth > Storm > (back to) Water
Pair (each beats the other):  Celestial <-> Shadow
Damage: strong x1.5, weak x0.75, otherwise x1.
```
* `PetCatalog`: `Element` on every pet (required, validated against `Config.Elements.Order`), assigned by species, look
  and theme (Phoenix/flame looks -> Flame, Penguin/icy -> Frost, Frog/Axolotl/sea colours -> Water, Bunny/Panda/leafy
  -> Nature, Bear/Dog/earthy -> Earth, Owl/Fox/electric -> Storm, Unicorn/angelic/halo -> Celestial, dark Secrets ->
  Shadow; Stormfang -> Storm). Every element has at least 3 pets and appears across several rarities.
  Helpers: `PetCatalog.GetElements(petId) -> {element...}`, `PetCatalog.ElementMultiplier(attackElement,
  defendElement) -> number` (from Config.Elements), `PetCatalog.ElementsOf(def)`.
* UI: an element badge (coloured pill with the element name, colour from `Config.Elements.Info`; no asset ids)
  on Index cards (only once discovered), the Index detail view (with "Strong vs X / Weak vs Y"), the Pets
  inventory panel and the roulette odds list. A small "Elements" help card in the Index shows the wheel.
* NPC tips: one NPC explains elements.

**Battle teams (Phase 3):** a battle team holds 3 pets; a 4th slot unlocks at Prestige 1 (or for Gems). Up to 3 saved
team presets (`Teams` in the profile). Team synergy shown live in the Team screen: 2 pets of the same element ->
+10% Power for them, 3 -> +20%, 4 -> +30%; 3+ different elements -> "Balanced" +10% Health for the team. Battles use
`ElementMultiplier` on every hit (dual-element attackers use their better element against the target).

**Fusion Machine (Phase 2, needs the per-copy pet data; unlocks at Prestige 1):** a crafted voxel machine built on each player's home plot from its buy pad (`FusionMachine`:
two input pods, a swirling cloud chamber, an output pod; fusion animation on the client). Two tabs:
* **UPGRADE:** 3 copies of the same pet and tier -> 1 of the next tier: Normal -> **Golden** (x1.5 stats/perk bonus,
  gold shimmer material) -> **Rainbow** (x2.5, animated rainbow shimmer). Costs Cloud Tokens by rarity.
* **MIX:** 2 different pets -> a brand-new hybrid: the body/species of the first, the colours, wings, accessory and
  element of the second added (Elements = both, deduplicated), rarity = the higher of the two, stats = average x1.2,
  a generated blended name (e.g. Penguin + Phoenix -> "Pengnix"), built by PetBuilder from a merged Look (the
  procedural pets make every hybrid look unique). Costs Tokens (or Gems for Secret/Mythic inputs). Hybrids live in a
  "Fusions" tab of the Index (not part of group rewards).
* Data: `Pets[petId] = count` stays for Normal copies; add `Tiers[petId] = {Golden = n, Rainbow = n}` and
  `Hybrids[uid] = {Body = petId, Style = petId, Elements = {...}, Name, Rarity, Tier}`; migration + delta save +
  ProfileSync like every other field; fusion is server-authoritative, validated and rate-limited, never consumes
  equipped pets without unequipping them first, and is atomic (inputs removed and output added in one step).

## Phase 2: Tycoon homes, the main mode (detailed by the player during Phase 1; build after the Stormfang round)
The player's words: "make sure the player's spot has the buttons and system working (you press E at the entrance to
obtain it) and you have there a spot purchasable for every tool or objective such as the kitchen (feeding the pet for
xp), machines, gym, fusion machine and everything so the tycoon system will work". So every home plot becomes a
classic Roblox tycoon: claim it at the gate, then build it up with buy pads.

**Claiming (replaces v2 auto-assignment in SpotService).** Each free plot's gate shows a ProximityPrompt "Claim Home"
(E, ObjectText "Free home"). Pressing it claims that plot for the session (one per player; refused during a match).
The SAVED progress is the player's home build (`Home` in the profile), not a plot number: it is rebuilt on whichever
plot they claim. A returning player whose last plot is free gets a side toast "Welcome back! Press E at your gate";
the tutorial arrow and the "My Spot" button lead to that gate (or the nearest free gate). Leaving releases the plot:
the build is removed and the gate shows "Claim Home" again. The nameplate/mailbox shows the owner, Home Level and
Prestige stars.

**Buy pads (the tycoon buttons).** Every purchasable thing has a build pad on the yard: a glowing voxel pad with a
floating sign (icon, name, price in Cash, "Lv 2 -> 3" for upgrades) and a ProximityPrompt "Buy" (E, HoldDuration
0.25). Only the owner sees and can use their pads (prompts disabled locally for everyone else; the server checks
ownership, price and prerequisites on every purchase). Buying deducts Cash, saves, and the structure assembles with a
quick voxel pop-in (client-side animation); new pads unlock in a tree so the yard fills up step by step, like a
real tycoon. Upgrades use the same pad, which stays in front of the built station.

**Stations (all voxel art in the detailed style, all on the plot):**
1. **Cloud Presses** (the money machines): up to 4 presses that puff glowing cloud blocks onto a conveyor into the
   **Collector**. Cash piles up in the Collector (shown on its sign); the owner steps on/presses E at the Collector to
   bank it. Each press upgrades L1-L10 (faster, bigger blocks). The first press pad is free/very cheap on claim.
2. **Pet Garden:** slots where the owner places Economy pets (from the Pets panel or a "Place pet" prompt); each
   placed pet makes Cash per second = Income x RarityScale x level factor x prestige multiplier, added to the
   Collector. Slots unlock with Garden levels.
3. **Kitchen:** cooks pet food with Cash (Snack, Meal, Feast; better recipes and faster cooking with Kitchen
   levels); food goes to the inventory. **Feeding** (from the Pets panel "Feed" button or the feeding bowl next to the
   kitchen): pick a pet and a food -> XP -> pet levels (`PetLevels`), which raise its stats
   (`PetCatalog.GetStats(petId, level)`): Income for Economy pets, Power/Health/Speed for Combat pets.
4. **Gym:** training slots for Combat pets; placed pets gain XP over time (more slots and faster with Gym levels).
5. **Fusion Machine:** section 11 (Upgrade: 3 copies -> Golden -> Rainbow; Mix: 2 pets -> hybrid), built on the plot
   from its pad; its window opens with E at the machine. **Unlocks only after Prestige 1** (the player's rule): before
   that its pad is a locked silhouette with "Unlocks at Prestige 1".
6. **Vault:** raises the Collector's cash cap and pays offline earnings (a % of the hourly income for up to N hours,
   shown in a "While you were away" toast on rejoin).
7. **House:** the home itself: **Cottage -> Villa -> Manor -> Sky Castle**. The player asked that the house upgrade
   only every 10 Home Levels so the castle is hard to get: Villa needs Home Level 10, Manor 20, Sky Castle 30 (the
   House pad shows "Reach Home Level N" until then). Each tier raises the max level of the other stations.
8. **Decor pads:** lamps, fences, flower beds, fountain, banners, a pet podium (the v2 showcase), cheap cosmetics that
   also add to Home Level.
9. **Arena Gate:** visible pad that unlocks pet battles (Phase 3); until then its sign says "Coming soon".

**Home Level and Prestige.** Every purchase or upgrade adds to Home Level. At Home Level 40 with the Sky Castle,
the Prestige pad appears: prestiging resets Cash and station levels (pets, food, decor choices kept) for +1 Prestige
star: a permanent x1.25 income multiplier per star, a Gems reward, a prestige badge on the nameplate, and at
Prestige 1 the Fusion Machine pad and the 4th battle-team slot (section 11).

**Economy.** Cash is the tycoon currency (HUD currency stack already shows it from the Cash attribute); Cloud Tokens
stay the obby/battle currency. Prices and incomes come from `Config.Tycoon` tables produced by an economy simulation
(targets: first purchase within 30 s of claiming, a steady new purchase every 1-3 minutes early on, first Prestige
after about 2-3 hours of active play, later prestiges faster thanks to the multiplier; no dead ends). Gems: developer
products (product ids in Config, placeholders until the owner creates them), idempotent ProcessReceipt; roulettes
also priced in gems (cheap) and the gems-only Secret roulette at the Storm Altar; respect PolicyService
paid-random-items restrictions and always show odds.

**Data.** `Home = {Level, Prestige, Stations = {[stationId] = level}, Garden = {slot -> petKey}, Gym = {slot -> petKey},
CollectorCash, LastSeen}`, `Food = {[foodId] = count}`, `PetLevels`, fusion data (section 11: `Tiers`, `Hybrids`),
all with migration + delta save + ProfileSync like every other field; server-authoritative, validated and
rate-limited; Cash income is computed on the server on a slow tick (1 s) and banked atomically.

**UI.** A Home window (menu tile "My Spot" becomes "Home": station list with levels, upgrade buttons, income per
second, prestige progress, "Go home"), the Feed panel, the Fusion window, readable pad signs (readability rule),
toasts for purchases, level-ups and offline earnings. **Tutorial:** after the Phase 1 steps: claim your home (E at a
gate), buy your first Cloud Press, collect your cash, build the Kitchen and feed a pet. **NPC tips** for the Kitchen
(Granny Owl), Gym (Coach Corgi), Fusion and Prestige.

## Phase 2 build contract (the engineers code strictly to these names)
**Ownership**
| Agent | Files |
|---|---|
| economy | `shared/TycoonCatalog.lua` (new), `tools/sim_tycoon.py` (new) |
| data | `server/Services/DataService.lua`, `shared/PetKeys.lua` (new), `server/Services/PetService.lua`, `client/Controllers/PetController.lua`, `client/State.lua` |
| homeworld | `server/Services/HomeBuilder.lua` (new, a module TycoonService requires), `client/Controllers/HomeFx.lua` (new) |
| tycoon | `server/Services/TycoonService.lua` (new), `server/Services/SpotService.lua` |
| care | `server/Services/PetCareService.lua` (new), `shared/PetCatalog.lua` (levels/stats only) |
| fusion | `server/Services/FusionService.lua` (new), `client/Controllers/FusionController.lua` (new), `shared/PetBuilder.lua` (tier finishes + hybrid looks only) |
| gems | `server/Services/GemService.lua` (new) + the Secret/gem roulette path in PetService once the data agent is done |
| ui | `client/Controllers/MenuController.lua`, `client/Controllers/IndexController.lua` (Fusions tab), `shared/TutorialSteps.lua`, `server/Services/TutorialService.lua`, `shared/NpcDialog.lua` |
Lead-owned: Config.lua, Main.server.lua, Main.client.lua, the docs.

**Pet keys (`shared/PetKeys.lua`).** Phase 2 gives pets per-copy variants, so a pet copy is identified by a key string:
`"<petId>"` (Normal), `"<petId>@Golden"`, `"<petId>@Rainbow"`, `"hyb:<uid>"` (a fused hybrid, may also carry `@Golden` /
`@Rainbow`). Profile: `Pets[petId] = count` stays for Normal copies; `Tiers[petId] = {Golden = n, Rainbow = n}`;
`Hybrids[uid] = {Body = petId, Style = petId, Elements = {...}, Name, Rarity, Tier}`; `Equipped` is a list of keys.
API: `Parse(key) -> {PetId, Tier, HybridId}`, `Make(petId, tier)`, `Count(profile, key)`, `Add(profile, key, n)`,
`Remove(profile, key, n) -> ok` (never below 0), `List(profile) -> {key...}`, `DefOf(key, profile) -> def` (catalog def,
or a merged def for hybrids whose Look combines both parents; `Look.Finish = "Golden"|"Rainbow"` for tiers),
`StatMultiplier(tier) -> 1 | 1.5 | 2.5`. Everything that shows or equips pets (PetService, PetController, menus,
Index, podium, NPC-free) works with keys; old profiles (plain petIds) are valid keys.

**Data (`DataService`).** Adds `Home = {Level, Prestige, Stations = {[stationId] = level}, Garden = {[slot] = key},
Gym = {[slot] = key}, CollectorCash, LastSeen}` (migrated from the reserved `Home.Rooms`), `Food = {[foodId] = count}`,
`PetLevels[key] = {Level, Xp}`, `Tiers`, `Hybrids`, `GemReceipts` (bounded set of processed purchase ids) and reserves
`Teams` for Phase 3. Cash/Gems/Food/CollectorCash save as deltas; Stations/Garden/Gym/Tiers/Hybrids/PetLevels per key;
a higher `Home.Prestige` wins the whole `Home` on merge (prestige resets stations). New API: `GetHome(player)` (copy),
`MutateHome(player, fn) -> ok` (fn edits a live table, no yields), `AddCash/SpendCash/GetCash`,
`AddGems/SpendGems/GetGems`, `AddFood/SpendFood/GetFood`, `GetPetLevel(player, key)`, `AddPetXp(player, key, xp)
-> levelsGained`. The player attributes `Config.Attr.Cash` / `Config.Attr.Gems` mirror the balances (the HUD shows them).

**`shared/TycoonCatalog.lua` (economy).** Data + pure functions, balanced by `tools/sim_tycoon.py` (a progression
simulation that proves the targets in the Phase 2 section). Stations (ids): `Press1..Press4` (Cloud Presses),
`Collector`, `Garden`, `Kitchen`, `Gym`, `Vault`, `House`, `FusionMachine`, `ArenaGate`, decor `DecorLamps`,
`DecorFence`, `DecorFlowers`, `DecorFountain`, `DecorBanners`, `DecorPodium`. Each: `{Id, Name, Kind, MaxLevel, Requires
= {Station = level, HomeLevel = n, House = tier, Prestige = n}, Price = {[level] = cash}, Effects = {[level] = {...}},
Slot = plot-local CFrame + Footprint}` (positions inside the `Config.Lobby.PlotSize` yard: house at the back, presses +
conveyor + collector on one side, garden opposite, kitchen/gym/vault/fusion/arena gate around, decor along the fence).
`HouseTiers` = Cottage (start), Villa (Home Level 10), Manor (20), Sky Castle (30), each raising other stations' caps.
`Prestige = {HomeLevel = 40, House = "SkyCastle", IncomeMultiplier = 1.25 per star, GemReward}`. `Foods` (Snack,
Meal, Feast: Price, Xp, CookSeconds, KitchenLevel). `Fusion` costs by rarity. Pet XP curve. API: `Get(id)`,
`PriceFor(id, level)`, `AvailablePads(home) -> {{StationId, NextLevel, Price, Locked = reason|nil}}`,
`HomeLevelOf(home)`, `IncomePerSecond(home, gardenDefs, prestige)`, `CollectorCap(home)`, `OfflineEarnings(home,
seconds, incomePerSecond)`, `XpToNext(level)`, `Validate()`.

**HomeBuilder (homeworld, server module) + HomeFx (client).** `HomeBuilder.Init(lobbyInfo)`, `PreparePlot(spotInfo)`
(gate "Claim Home" ProximityPrompt named `ClaimPrompt`, attribute `SpotIndex`), `SetOwner(spotInfo, player|nil)`,
`SetStation(spotInfo, stationId, level)` (builds or replaces the station's detailed-voxel model `Station_<Id>` with
attributes `StationId`, `Level`, `BuiltAt` under the plot's `Home` folder; level 0 removes it), `SetPads(spotInfo, pads)`
(pad models `Pad_<StationId>` with a readable sign: icon, name, "Lv a -> b", price or lock reason; ProximityPrompt `BuyPrompt`
ActionText "Buy", HoldDuration 0.25, attributes `StationId`, `OwnerUserId`), `SetCollector(spotInfo, cash, cap)` (attribute
updates only), `ClearPlot(spotInfo)`. Whole fully-built plot <= ~900 parts. HomeFx (client): voxel pop-in when a
`Station_*` appears, press puffs + conveyor blocks + collector glow (client-only visuals), disables `BuyPrompt`s whose
`OwnerUserId` is not the local player, and shows the collector amount.

**TycoonService (tycoon).** `Init(lobbyInfo, {DataService, PetService, SpotService})`; claiming via `ClaimPrompt`
(server Triggered; one plot per player; refused in a match); SpotService no longer auto-assigns: `GetSpot(player)`
returns the claimed plot, `Teleport` goes home or to the nearest free gate; on leave the plot is released and cleared.
Purchases via `BuyPrompt` (owner, `AvailablePads`, `SpendCash`, `MutateHome`, `HomeBuilder.SetStation/SetPads`, toast).
Income: a 1 s server tick adds presses + garden income into `Home.CollectorCash` (capped by the Vault); the Collector
(prompt or touch) banks it with `AddCash`; offline earnings on load ("While you were away" toast). Prestige pad.
Remote `HomeAction(action, arg)`: "Upgrade" stationId (from the Home window), "GardenSet" {slot, key|nil}, "Collect",
"Prestige", "GoHome". Signals `HomeChanged(player)`, `Claimed(player, spotInfo)`, `Prestiged(player, stars)`.
API `GetPlot`, `GetHome`, `Buy`, `Collect`, `Prestige`, `IncomePerSecond`.

**PetCareService (care).** Remote `PetCare(action, a, b)`: "Cook" (foodId, qty: Cash, a cooking queue on the Kitchen
with CookSeconds, finished food goes to `Food`), "Feed" (key, foodId: XP, level-ups toast), "GymSet" (slot, key|nil:
Combat pets only; passive XP per minute by Gym level). `PetCatalog.GetStats(petId, level, tier)` scales by rarity,
level and tier and is used everywhere stats show. Economy pets go to the Garden, Combat pets to the Gym.

**FusionService + FusionController (fusion).** Remote `Fusion(action, a, b)`: "Upgrade" (key: 3 copies of the same key
-> the next tier), "Mix" (keyA, keyB: two different pets -> a hybrid). Requires Prestige >= 1 and the FusionMachine
station; atomic; never consumes equipped/garden/gym copies without unequipping them first. PetBuilder: `Look.Finish`
Golden (gold-tinted palette + sparkle accents) and Rainbow (client-side hue shift), hybrid looks merged from both
parents; names blended ("Pengnix"). The window opens with E at the machine. The Index gets a "Fusions" tab (ui agent).

**GemService (gems).** `Config.Gems.Products` (placeholders, product id 0 = not created yet: the owner creates them on
the Creator Hub and pastes the ids), idempotent `MarketplaceService.ProcessReceipt` (GemReceipts), `PolicyService`
paid-random-items check (hide gem-priced roulettes where restricted), roulettes with `GemPrice`, and the gems-only
**Secret roulette** at the Storm Altar (its prompt opens the shop on that roulette; `AllowSecret = true`). Odds always shown.

**UI (ui).** Menu tile "My Spot" becomes "Home": the Home window (stations with levels and Upgrade buttons, income per
second, Collector cash, house tier, prestige progress, "Go home"); the Pets panel gets "Feed", "Place in Garden",
"Train in Gym" and shows tiers/hybrids/levels; the Shop gets a Gems tab; the Index gets the Fusions tab. Tutorial steps
appended (claim home, buy the first press, collect cash, build the kitchen and feed a pet); NPC tips for Kitchen, Gym,
Fusion, Prestige and Gems.

## Phase 3: Pet battles (detailed by the player during Phase 1; build after Phase 2)
The player's words: "create an Arena in the map for players to fight in it; at the arena there will be a special
events system (like in the chicken fight game) like a boss to defeat (everyone gets in this fight for the reward);
a button on the screen for controlling the pet (attack, retreat; works only in an arena or pvp); and a portal for
fighting NPC pets by levels so players can go there and fight for tokens."

**Battle Arena (lobby landmark, world).** A big detailed-voxel colosseum on its own cloud island linked to the plaza by
a bridge: a central battle floor (the boss stage), two or more PvP duel rings, spectator stands, an event board
(next event + countdown), a trophy leaderboard, and the Arena Gate pads of the homes point here. Battle zones are
tagged areas: the battle controls only work inside them (arena floor, duel rings, trial pockets).

**Teams.** Section 11: 3 pets (4th slot at Prestige 1), up to 3 saved presets, element synergy. The battle team
follows the owner into a battle zone and fights there; outside battle zones pets just follow as usual.

**Real-time battles, server-authoritative.** Pets move on the battle floor (10 Hz server sim, client interpolation):
move speed from Speed, melee or ranged by species, damage = Power x level factor x ElementMultiplier x small
variance, HP from Health x level, specials by `Special.Kind` (Blast = area, Heal, Shield, Storm = damage over time,
Pounce = dash strike, Freeze = stun, Beam = line). Client effects: lunges, hit flashes, damage numbers (never in the
screen centre), voxel particle bursts per special and element, knock-out poof; a downed pet returns after the fight.

**Battle controls (on screen, ONLY inside battle zones):** a compact battle HUD at the bottom/side (never centred):
each team pet's HP bar, element badge and special meter; buttons **ATTACK** (pets engage; tap/click an enemy to focus
it), **RETREAT** (pets break off and run back to the owner, take reduced damage and slowly regain HP while retreating;
short cooldown before attacking again) and one **SPECIAL** button per pet (lights up when its meter is full).
Keyboard F = Attack, R = Retreat, 1-4 = specials; gamepad mapped; touch buttons sized for phones.

**PvE: the Trial Portal (lobby).** A portal (named `Portal_Trials`, styled like the difficulty portals) opens a level
list of NPC pet teams: Level 1..30, each harder (higher levels, rarities, element mixes, a mini-boss every 5
levels). Beating level N unlocks N+1; rewards Cloud Tokens (big first-clear bonus, smaller repeat rewards) and pet
XP. Fights run in private battle pockets in the sky (instanced like obby matches) so many players fight at once.

**PvP.** In the arena: walk onto a duel ring and challenge another player (request -> accept), or join the quick
queue. Team vs team; rewards trophies (leaderboard) and tokens; nobody ever loses pets.

**Special events system (arena).** An event scheduler (every ~20 minutes, configurable; announced 2 minutes before by
a side toast to everyone and a countdown on the event board) runs events on the arena floor:
* **Boss Raid** (the main event): a giant detailed-voxel boss (rotating roster, each with an element and mechanics:
  e.g. Storm Titan, Lava Golem, Frost Wyrm, Shadow Hydra) appears; everyone in the arena can join with their team.
  Shared boss HP scales with the number of participants; telegraphed attacks (glowing circles/lines on the floor to
  RETREAT from), minion waves, an enrage timer. Rewards for everyone who took part, scaled by damage contribution
  tier (Tokens, pet XP, a chance of Gems and of an exclusive event pet).
* The scheduler supports more event types later (e.g. Double Rewards hour, King of the Ring).

**Progression.** Pet XP from battles + Kitchen food + Gym; levels raise stats (`PetCatalog.GetStats`). Rewards are
Tokens (shop, roulettes), trophies (rank/leaderboard), rare Gems.

