# Nimbus Climb

> *Climb the storm. Together.*

A cosy, co-op **cloud parkour** game for Roblox. You live in a floating cloud village, step into one of five
glowing **portals** with up to three friends, and get flown to a freshly generated **sky course** that you climb
as a team: dash over gaps, dodge spinning bars, lightning and swinging beams, share checkpoints and pick each
other back up. Along the way you collect **cloud tokens**, and back home you spend them on **winged pets** (from
roulettes) and **usable items**. Every player also gets a personal **spot** in the village to show off their pets.

Everything is built from plain parts and particles (no asset ids, no toolbox models), and all text uses one
small `Theme` module, so the whole game shares the same chunky, friendly look.

## How to open the game

**Just play (nothing to install):** open `play/NimbusClimb.rbxlx` in Roblox Studio (double-click it, or
File -> Open from File) and press **Play**. It is a ready-made copy of everything in `src/`.

**One-click Rojo launchers (to edit the code with live sync):** extract the ZIP first (never run anything from
inside it), then start the Rojo server with the launcher for your computer. The first run downloads Rojo 7.7.1
(about 5 MB). Keep the window open, open a Baseplate place in Studio, click **Plugins -> Rojo -> Connect**
(install the Rojo 7.7.1 plugin once), then press **Play**.

- **Windows:** double-click `Start-Rojo-Windows.bat`. If it says the server stopped with "already in use",
  another Rojo window is still open: close it and try again.
- **Mac:** `Start-Rojo-Mac.command` is blocked the first time because it came from a download. Easiest fix
  (works on every macOS): open Terminal, type `bash ` (with a trailing space), drag the file from Finder into the
  window and press Enter. Alternatives: right-click -> **Open** (macOS 14 and earlier), or double-click once,
  then System Settings -> Privacy & Security -> **Open Anyway** (macOS 15 and later; the button stays for about an
  hour). If macOS asks about the Downloads folder, click **Allow**.

Prefer the command line? In this folder run `rojo serve` (needs Rojo 7.7.1, [Rokit](https://github.com/rojo-rbx/rokit)
or the VS Code "Rojo" extension are the easy ways to get it).

**Place settings that matter**

- **Max Players: 16 or less** (a place setting, in Studio's Game Settings or the place's settings on the Creator
  Hub). The lobby has exactly 16 spots (`Config.Lobby.SpotCount`); a 17th player would still play but would have
  no spot.
- **Saving needs a published place.** Tokens, pets, items and stats are saved in a DataStore, and DataStores only
  work in a place published to Roblox (File -> Publish to Roblox). In Studio also turn on Game Settings ->
  Security -> **Enable Studio Access to API Services**. Without these the game still runs, it just forgets
  everything when you stop. Saves happen on leave, every 90 s and at server shutdown (older v1 token saves are
  migrated once).
- Leave *StreamingEnabled* off. Everything else (sky, lighting, gravity, lobby) is created by the scripts, so an
  empty baseplate is all you need. To test parties use Test -> Clients and Servers with 2-4 players.

## Controls

| Action | PC | Mobile | Gamepad |
|---|---|---|---|
| Move | `W` `A` `S` `D` | thumbstick | left stick |
| Jump | `Space` | jump button | `A` |
| Run (drains stamina) | hold `Shift` | **RUN** button (tap to toggle) | `L3` (toggle) |
| Dash (35 stamina, 1.6 s cooldown, works in the air) | `Q` | **DASH** button | `B` |
| Use an item | `1` `2` `3` `4` (or click / tap a slot) | tap a slot | - |
| Close a window | `Esc` or the red X | red X | - |

## The five portals

Stand on a portal pad to join its party (1-4 players). A 15 s countdown starts (4 s once the party is full),
then everyone is flown to the start platform of a new course. Every course is generated from a seed, in one of
four shapes (Straight, Zigzag, Serpent, Spiral) and mixed from stage themes (moving clouds, spinning bars, storms,
lightning, vanishing steps, cannons, wind, pendulums, co-op plate bridges, dash-only gaps ...), and it is
validated for reachability before it is built.

| Portal | Stars | Stages | Time limit | Void fall costs | Win bonus | Feel |
|---|---|---|---|---|---|---|
| **Easy** | 1 | 4 | 9 min | 10 HP | 10 tokens | Chill clouds and wide steps. |
| **Medium** | 2 | 5 | 12 min | 15 HP | 20 tokens | Moving clouds, spinning bars, your first co-op bridge. |
| **Hard** | 3 | 6 | 15 min | 22 HP | 35 tokens | Vanishing steps, lightning, swinging beams. |
| **Extreme** | 4 | 8 | 20 min | 30 HP | 60 tokens | Dash-only gaps, storms, narrow beams. Bring friends. |
| **Saint** | 5 | 10 | 25 min | 40 HP | 100 tokens | Tiny steps, relentless hazards. |

Team rules: the first player to touch a checkpoint sets it for everyone, heals the living (35 %) and revives all
downed teammates. A lethal hit does not kill you, it leaves you **downed** (1 HP, frozen) until a teammate reaches
the next checkpoint. If everybody is downed, or time runs out, the team loses; if every living player stands on the
finish pad, it wins. Falling into the void, or missing a jump onto a lower lap of a spiral, costs health and puts
you back at the team checkpoint. Golden tokens (worth 5) sit on the riskiest steps.

## Your spot

Every player owns one of **16 cloud islands** on the village's outer ring. It is saved with your profile (you get
the same one back when it is free), shows your name and totals, and has a podium with a slowly spinning copy of
your best pet. You respawn there, and the **Spot** button (house icon) teleports you home. Not during a climb.

## Pets and roulettes

26 chibi winged pets in six rarities (Common 6, Uncommon 6, Rare 5, Epic 4, Legendary 3, Mythic 2) fly beside
their owner, and everybody sees everybody's pets. Visit the **shop island** (four roulette machines and an item
counter) or press the **Shop** button, pick a roulette and spin. Duplicates stack (up to 99 per pet).

| Roulette | Price | Odds per spin (pets inside a rarity are equally likely) |
|---|---|---|
| **Cloud** | 50 tokens | Common 60 %, Uncommon 28 %, Rare 10 %, Epic 2 % |
| **Storm** | 250 tokens | Uncommon 35 %, Rare 40 %, Epic 20 %, Legendary 5 % |
| **Sky** | 1,000 tokens | Rare 35 %, Epic 45 %, Legendary 17 %, Mythic 3 % |
| **Celestial** | 5,000 tokens | Epic 45 %, Legendary 40 %, Mythic 15 % |

Equip up to **3** pets from the Pets window. Each pet has one or two perks: **Max Health**, **Cloud Tokens**
(more tokens per pickup), **Stamina Regen** and **Checkpoint Heal**. Perks add up, with caps (+50 % health, +100 %
tokens, +60 % stamina regen, +100 % checkpoint heal). Pets never change run speed or jump height, and your
loadout is locked while a climb is running. The mascot is the Mythic **Cloudy Dragon**.

## Items

Bought in the shop for cloud tokens, carried up to 5 of each, used on keys `1`-`4` during a climb (they do nothing
in the lobby or during the intro countdown). Slot 4 is a locked placeholder for a future item.

| Slot | Item | Price | What it does |
|---|---|---|---|
| 1 | **Heal Cloud** | 30 | Heals 40 % of your max health. |
| 2 | **Shield Bubble** | 45 | Nothing can hurt you for 8 seconds. |
| 3 | **Phoenix Feather** | 150 | Revives the nearest downed teammate at 50 % health (only used up if someone was revived). |

## The screen

Nothing the game says appears in the middle of the screen. Layout, with a compact HUD:

- **Left, vertically centred: the menu column** of five round buttons: Inventory, Pets, Shop, Spot, Stats.
  Windows you open are centred on purpose (you asked for them) and close with Esc.
- **Right: toasts** stack under the token counter (top-right) and the compact result card shows up at the right
  edge after a climb.
- **Top-left:** party panel in the lobby, match panel (timer, checkpoints, tokens, team) in a climb.
- **Bottom-left:** health and stamina. **Bottom-centre:** the item hotbar (1-4).

## Rebuilding the place file

`play/NimbusClimb.rbxlx` is generated from `src/`; never edit it by hand. After changing code, rebuild it from this
folder with [Rojo](https://rojo.space) 7.7.1:

```bash
rojo build default.project.json -o play/NimbusClimb.rbxlx
```

It contains only the three script containers below (plus the lighting technology); the world is built by the
scripts when the game starts.

| Folder | Becomes |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

## Game icon

The icon is the Cloudy Dragon on a sky background: `branding/icon-512.png` is the file to upload to Roblox
(`icon-1024.png` and the source `icon.svg` are there too). It is placeholder-quality vector art; see
`branding/README.md` for the upload steps, design notes and how to replace it.

## Tests

```bash
pip install lupa            # once (also needs Python 3 and Node 18+; npm packages install on first use)
tools/run_checks.sh         # everything, about 2 minutes
tools/run_checks.sh --quick # shorter smoke test (fewer layout seeds), about 75 s
tools/run_checks.sh --static   # only the fast checks
```

The script exits non-zero if anything fails and runs three steps:

1. **`tools/syntax.py`**: every `.lua` file must parse as plain Lua 5.1 (no Luau-only syntax).
2. **`tools/check.mjs`**: static analysis (undefined globals, deprecated APIs, raw fonts, bad `Instance.new`,
   missing `require`s, and the public API listed in `tools/contract.json`).
3. **`tools/smoke.py`**: loads the real modules into a Roblox mock (`tools/robloxmock.lua`) and plays the game:
   5 difficulties x 300 generated courses audited (reach, headroom, cannons, tokens), full matches (victory,
   defeat, timeout, leaving, concurrent slots), damage and the fall rule, hazards, spots, pets, roulettes, items,
   saving (also during DataStore outages), and the whole client UI including the "nothing in the middle of the
   screen" rule on desktop and phone sizes. Handy flags: `-v`, `--only match_victory,damage_rules`, `--list`,
   `--seeds N`, `--strict`.

The mock is not a physics engine (characters do not walk, moving platforms are not simulated), so test the feel
in Studio too.

## Project layout

```
default.project.json   Rojo project           play/NimbusClimb.rbxlx   ready-made place file
Start-Rojo-*           one-click launchers    branding/                game icon (see branding/README.md)
tools/                 syntax check, static analysis, smoke test (see "Tests")
ARCHITECTURE.md + ARCHITECTURE_V2.md   module contracts (v2 wins where they differ)

src/shared   Config (every number)  Theme  Util  Remotes  PetCatalog  ItemCatalog  PetBuilder
src/server   Main.server.lua; Services: Lighting, Lobby, Player, Data, Damage, Token, Hazard, Course (layout +
             builder), Match, Portal, Spot, Pet, Item
src/client   Main.client.lua; State; UI/CloudUI; Controllers: Movement, Hud, DamageFx, Notify, Menu, Hotbar,
             Pet, TokenFx
```

The **server is authoritative** (health, tokens, pets, items, checkpoints, matches); clients only do input,
movement feel and UI. Behaviour is attached with `CollectionService` tags (`Config.Tags`). Every tunable number,
including roulette prices and odds, difficulties and physics, lives in `src/shared/Config.lua`.

Have fun climbing!
