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

## ART DIRECTION (decided by the player after the plan): blocky pixel / voxel style EVERYWHERE
**This section overrides sections 6, 7 and 8 wherever they mention smooth terrain, round parts or Ball shapes.**
The player wants the whole game in a clean, high-quality **voxel ("pixel") style**, like Pet Simulator 99 cube pets
and the blocky RollAnt-style world with studded surfaces. Everything is built from axis-aligned **cubes / boxes on a
grid**: pets, NPC pets, tokens, trees, flowers, lamps, signs, decor, the sky dragon, the cloud islands and the ground.
Why: on a grid every detail lines up exactly (eyes, mouths, ears can never look stuck on), one consistent style
looks deliberate and polished, and blocky shapes read well at small sizes (Index tiles, hotbar).

* **`shared/Voxel.lua` (new, owned by the pets agent)** — the shared voxel kit everyone uses:
  ```lua
  Voxel.Parse(layers, legend) -> grid          -- layers: list (bottom->top) of string rows; legend: char -> paletteKey
  Voxel.Build(grid, opts) -> Model             -- opts: { VoxelSize = studs, Palette = {key -> Color3 | {Color, Material, Transparency}},
                                               --   Anchored = true, Studs = false (top-surface studs), Name, PrimaryKey }
  Voxel.Box(parent, cframe, size, color, material, props) -> Part   -- one block helper (Anchored, SmoothPlastic default)
  Voxel.Merge(grid) -> { {min=Vector3int, max=Vector3int, key=paletteKey}, ... } -- greedy merge of same-key runs
  ```
  `Build` greedily merges runs of same-key voxels into larger box Parts (3D greedy meshing) so a 12x12x12 pet stays
  around 40-90 parts. Parts: `Anchored`, `CanCollide/CanTouch/CanQuery` false unless the caller asks, `CastShadow`
  false for small parts, Material SmoothPlastic (or the palette's material). No studs on pets; studs allowed on
  world surfaces (`TopSurface = Enum.SurfaceType.Studs`).
* **Pets (PetBuilder, pets agent):** rewrite every species as hand-designed voxel art (about 10-14 voxels tall,
  Pet-Sim style: big cube head, small body, stubby feet), data-driven per species with palette keys mapped from
  `Look` (Primary, Secondary, Eye, Blush, Accent, Wing...). Eyes are 2x2 or 2x3 dark voxels with a 1-voxel white
  highlight, flush with the face; blush voxels; species features (ears, snout, beak, horns, tail) as voxels;
  accessories voxel (crown, halo, leaf, mushroom, scarf, antlers, flower, horns); wings as voxel slabs per WingStyle,
  grouped so Animate can flap them about a hinge. Rarity flair: Legendary+ subtle sparkle, Secret pets an aura of
  floating voxels. **Same public API** (`Build/Animate/GetHeight`, `WingL/WingR`, Animate from the PrimaryPart, works in
  ViewportFrames). Part budget after merging: <= ~90 per pet. The Cloudy Dragon: white/sky-blue voxel dragon, gold
  voxel horns, cloud-puff voxel wings and tail tuft (it is the icon mascot: make it the best one).
* **Tokens (TokenService/TokenFx):** a voxel coin (stepped round coin silhouette, gold with a lighter rim and a cloud
  glyph in voxels on both faces) and a soft halo that moves with the coin; golden tokens bigger/brighter.
* **World (world agent):** NO smooth terrain. Cloud islands = blocky voxel clouds (stacked rounded-ish voxel masses of
  large cubes, e.g. 4-6 stud voxels, white/very light blue with slightly darker under-layers for depth, greedy-merged);
  ground = tiled studded blocks (`TopSurface Studs`) with per-tile colour variation (grass in 3-4 close greens, path
  tiles in sand/stone/wood plank colours, flower pixels), clear path borders, block trees (trunk + leafy cube
  canopies in 2-3 greens, some blossom pink), blocky lamps/benches/fences/banners/fountains (water = translucent
  blue blocks), bright cheerful colours (still not neon-blinding). The roulette machines, portals, shop and home plots
  get the same blocky style. A soft `Clouds` sky object and `Atmosphere` may stay for the sky. Part budget for the
  whole lobby after merging: <= ~5000 (prefer bigger blocks over many small ones; reuse colour variation sparingly).
* **Sky Dragon (skydragon agent):** a voxel eastern dragon: each body segment a small voxel chunk (sage-green scale
  voxels, cream belly voxels, a darker spine ridge), voxel head with gold horns, whiskers as thin block chains, voxel
  cloud puffs trailing. Same flight/animation rules as section 7, <= ~220 parts.
* **NPC pets** use PetBuilder (so they are voxel automatically) at Scale ~2.2 on blocky pedestals.
* **UI** stays the chunky cloud UI (2D), with a subtle pixel accent (e.g. pixel-style corner notches) only if it looks good.

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

## Phase 2 outline (tycoon) — design only, do not build yet
Home on each plot: rooms **Kitchen** (makes pet food + cash), **Garden** (economy pets work here: cash/s =
sum(Income * RarityScale * level factor)), **Gym** (combat pets gain XP over time), **Vault** (cash cap, offline
earnings), **Arena Gate** (unlocks battles). Rooms have levels bought with Cash via plot buttons and a Home window.
Prestige at Home level 25: reset Cash and room levels for a permanent income multiplier and Gems. Gems: developer
products (product ids in Config, placeholders until the owner creates them), idempotent ProcessReceipt; roulettes
priced in gems too (cheap) and a gems-only Secret roulette; respect PolicyService paid-random-items restrictions and
always show odds.

## Phase 3 outline (pet battles) — design only
Arena island in the lobby. PvE ladder (10 tiers of NPC teams) and PvP challenges between players in the arena.
Teams = up to 3 equipped combat pets. Server-simulated auto-battle (10 Hz ticks: Speed -> attack interval, Power ->
damage, Health -> HP); a special meter charges and the owner presses SPECIAL to fire the pet's `Special` (Kind decides
the effect). Client plays animations: lunges, hit flashes, damage numbers, special effects per Kind. Pet food (bought
with Cash) feeds pets -> XP -> level -> `PetCatalog.GetStats(petId, level)`. Rewards: Cloud Tokens, trophies, rare Gems.
