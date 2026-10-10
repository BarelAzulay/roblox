# Nimbus Climb

> *Climb the storm. Together.*

A cosy, co-op **sky village** game for Roblox. You live in a floating cloud village, step into one of five
glowing **portals** with up to three friends, and get flown to a freshly generated **sky course** that you climb
as a team: dash over gaps, dodge spinning bars, lightning and swinging beams, share checkpoints and pick each
other back up. Along the way you collect **Cloud Tokens**, and back home you spend them on **pets** (from
roulettes) and **usable items**, fill your **Pet Index**, and show off your best pet on your own **home plot**.

Version 3 turns Nimbus Climb into a multi-concept game: the climb (obby) stays as a side mode, **tycoon homes**
and **pet battles** are coming in the next two updates. This build (v3 phase 1) brings the new look, the
pet collection and everything those updates build on.

Everything is built in code from plain parts and particles (no toolbox models), and all text uses one small
`Theme` module, so the whole game shares the same chunky, friendly look. The only asset id in the code is the
owner's own Stormfang artwork (`Config.Art.StormfangImage`).

## What's new in v3

- **Detailed voxel art everywhere.** Every pet is sculpted in a fine "MagicaVoxel" style: rounded heads, 2-3
  shades per colour, fur patterns, claws, inner ears and eyes carved *into* the face (dark iris, white highlight,
  brows), not stuck on. Each species has its own details (cat tufts, corgi ears, fox ruffs, dragon crests ...).
  Your own pets use the full-detail model, other players' pets a lighter one, so the game stays smooth.
- **A brighter, warmer village.** Puffy sculpted voxel clouds in soft whites and blues, real moving sky clouds,
  detailed ground (stone, sand and wooden paths, lawns, flower beds), trees, lamps, benches, fences, banners and
  fountains, and a friendlier afternoon sun. Tokens are now detailed gold coins with a cloud emblem, and their
  glow moves with the coin.
- **The Sage Dragon.** A giant eastern dragon (sage-green scales, gold antlers, whiskers and a flowing mane)
  swims slow loops in the sky above the village, trailing little cloud puffs. It is only for looks.
- **Stormfang and the Storm Altar.** The owner's own creature, a storm lynx in charcoal armour with glowing blue
  eyes, neon claws and a cyan forehead gem, riding a little storm cloud, is the game's signature **Secret pet**.
  It prowls on the **Storm Altar**, a dark storm-cloud island at the edge of the village with a ring of
  glowing crystals (cross its bridge from the street and press **E** at the altar). The altar awakens in the
  next update, where Secret pets will be summoned with Gems.
- **Pet elements.** Every pet now has one of eight elements (see [Elements](#elements)), shown as a coloured
  badge in the Pet Index, the Pets window and the roulette odds list.
- **The Pet Index.** A collection book of every pet: undiscovered pets are black `???` silhouettes; complete a
  rarity group to claim a token reward (see [Pet Index](#pet-index)).
- **A tutorial.** Nimbus, the Cloudy Dragon, guides new players step by step from a small side panel, with a
  golden arrow and a sparkle trail that lead the way (see [First steps](#first-steps-the-tutorial)).
- **NPC pets.** Six big friendly pets around the plaza share tips: walk up and press **E** to talk.
- **Bigger, clearer UI.** Larger text everywhere (it scales with your screen and never gets too small on a
  phone), a new menu of square tiles, a new health and stamina card with a token counter above it, and readable
  name tags in the world that keep the same size on screen when you zoom out.
- **Portal lock-in.** Once you step on a portal pad you stay in the party until launch; the big red **Leave**
  button is the only way out, and friends outside see the countdown right on the gate.
- **Home plots.** The 16 player spots are now big fenced home plots ready for the tycoon homes of the next
  update.
- **Developer tools for the owner** (see [Developer tools](#developer-tools-owner-only)): a DEV panel and chat
  commands to get every pet, add tokens, replay the tutorial or reset your data while testing.

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
  Hub). The village has exactly 16 home plots (`Config.Lobby.SpotCount`); a 17th player would still play but
  would have no plot.
- **Saving needs a published place.** Tokens, pets, items, stats, Pet Index progress and the tutorial step are
  saved in a DataStore, and DataStores only work in a place published to Roblox (File -> Publish to Roblox). In
  Studio also turn on Game Settings -> Security -> **Enable Studio Access to API Services**. Without these the
  game still runs, it just forgets everything when you stop. Saves happen on leave, every 90 s and at server
  shutdown (older v1 and v2 saves are migrated automatically).
- **After publishing an update, restart the live servers.** Once the game is published and people play it, every
  time you publish a new version open the Creator Hub -> your experience -> **Servers** and choose **Shut Down All
  Servers**. Old servers still running the previous version do not
  know the new save fields and could overwrite them (for example replaying the tutorial rewards). Players simply
  rejoin into the new version.
- Leave *StreamingEnabled* off. Everything else (sky, lighting, gravity, the village) is created by the scripts,
  so an empty baseplate is all you need. To test parties use Test -> Clients and Servers with 2-4 players.
- **The Stormfang artwork** (Storm Altar poster, Stormfang's Pet Index banner) is the image id in
  `Config.Art.StormfangImage`. If it shows up blank, the image is still waiting for Roblox moderation, or the id
  needs replacing with your own upload.

## Controls

| Action | PC | Mobile | Gamepad |
|---|---|---|---|
| Move | `W` `A` `S` `D` | thumbstick | left stick |
| Jump | `Space` | jump button | `A` |
| Run (drains stamina) | hold `Shift` | **RUN** button (tap to toggle) | `L3` (toggle) |
| Dash (35 stamina, 1.6 s cooldown, works in the air) | `Q` | **DASH** button | `B` |
| Use an item | `1` `2` `3` `4` (or click / tap a slot) | tap a slot | - |
| Talk to an NPC pet, use the Storm Altar | `E` | tap the prompt | `X` |
| Close a window | `Esc` or the red X | red X | `B` |

## First steps: the tutorial

New players meet **Nimbus**, the Cloudy Dragon, in a small card on the left of the screen (never in the middle).
Nine short steps teach the basics: say hello, visit your home plot, find the Cloud Shop, spin your first
roulette (Nimbus gives you **50 Cloud Tokens** for it), equip your new pet, peek into the Pet Index, step into the
Easy portal, play your first climb to the end, and collect **100 Cloud Tokens** at the end. A golden arrow, a sparkle trail and a
distance sign point at places in the world; a pulsing ring points at menu tiles.

Tap Nimbus' portrait to fold the card into a small bubble (and again to open it). The **Skip tutorial** link
ends it (it asks first). Your step is saved, so the tutorial continues where you left off.

## The village

- **The plaza** in the middle, with the five difficulty **portals** on a ring around it.
- **The shop island** (follow the boardwalk): four roulette machines and the item counter.
- **Six NPC pets** stand along the plaza and the paths. Each one has a name tag; walk up and press **E** to
  talk. They cycle through a few tips each (Next / Close):

  | NPC | Talks about |
  |---|---|
  | **Sparky Fox**, Movement Trainer | running, dashing, dash-only gaps, items |
  | **Captain Penguin**, Co-op Captain | parties, reviving teammates, Phoenix Feather, pressure plates |
  | **Granny Owl**, Pet Expert | roulettes and their chances, equipping pets, the Pet Index |
  | **Coach Corgi**, Token Coach | earning more tokens: win bonus, golden tokens, harder portals, token perks |
  | **Mayor Panda**, Village Mayor | your home plot, the podium, the coming tycoon homes |
  | **Professor Axolotl**, Element Scholar | elements, the coming Pet Battles, the Storm Altar and Secret pets |

- **The Storm Altar** on its dark storm cloud at the village edge, with Stormfang prowling over the portal
  disc. Press **E** at the altar for a peek at what is coming.
- **The 16 home plots** on the big outer ring (see [Your home plot](#your-home-plot)).
- **The Sage Dragon** in the sky above it all.

## The five portals

Stand on a portal pad to join its party (1-4 players). A 15 s countdown starts (4 s once the party is full),
then everyone is flown to the start platform of a new course. While the countdown runs you are **locked in**:
soft walls in the portal's colour keep you on the pad, and the only way out is the big red **Leave** button in
the party panel (top-left). Everyone else walks through those walls freely. A name tag above each gate shows
its party ("2/4 players") and status, and friends standing next to the portal see a big countdown on the gate.

Every course is generated from a seed, in one of four shapes (Straight, Zigzag, Serpent, Spiral) and mixed
from stage themes (moving clouds, spinning bars, storms, lightning, vanishing steps, cannons, wind, pendulums,
co-op plate bridges, dash-only gaps ...), and it is validated for reachability before it is built.

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

## Your home plot

Every player owns one of **16 home plots** on the village's outer ring: a fenced grass yard with a gate, a
mailbox and a pet podium. It is saved with your profile (you get the same one back when it is free). The name
tag over the mailbox shows your avatar, your name and your pet and token totals, and the podium shows a slowly
turning copy of your rarest pet. You respawn there, and the **My Spot** tile teleports you home (not during a
climb). The middle of the yard is kept empty on purpose: that is where your tycoon home will be built in the
next update.

## Pets and roulettes

**30 pets** in seven rarities fly beside their owner, and everybody sees everybody's pets: Common 6, Uncommon 6,
Rare 5, Epic 4, Legendary 3, Mythic 2 and **Secret 4** (Stormfang, Eclipse Dragon, Obsidian Phoenix, Phantom
Kitsune). Visit the **shop island** or press the **Shop** tile, pick a roulette and spin. Duplicates stack (up to
99 per pet).

| Roulette | Price | Odds per spin (pets inside a rarity are equally likely) |
|---|---|---|
| **Cloud** | 50 tokens | Common 60 %, Uncommon 28 %, Rare 10 %, Epic 2 % |
| **Storm** | 250 tokens | Uncommon 35 %, Rare 40 %, Epic 20 %, Legendary 5 % |
| **Sky** | 1,000 tokens | Rare 35 %, Epic 45 %, Legendary 17 %, Mythic 3 % |
| **Celestial** | 5,000 tokens | Epic 45 %, Legendary 40 %, Mythic 15 % |

Secret pets are in none of these roulettes: they will come from the gems-only Secret roulette at the Storm
Altar in the next update.

Equip up to **3** pets from the Pets window. Each pet has one or two perks: **Max Health**, **Cloud Tokens**
(more tokens per pickup), **Stamina Regen** and **Checkpoint Heal**. Perks add up, with caps (+50 % health, +100 %
tokens, +60 % stamina regen, +100 % checkpoint heal). Pets never change run speed or jump height, and your
loadout is locked while a climb is running. The mascot is the Mythic **Cloudy Dragon**.

Every pet also has a **role** (Economy pets will earn Cash at your home, Combat pets will fight in Pet Battles),
battle **stats** (Income, Power, Health, Speed; higher rarities are much stronger) and a named **special attack**
(for example Stormfang's *Storm Pounce* or the Cloudy Dragon's *Cloud Breath*). The Pet Index shows them already;
they come into play with the next two updates.

## Elements

Every pet has one element. They matter in the coming Pet Battles: a strong hit deals **x1.5** damage, a weak
one **x0.75**, everything else x1.

- **The wheel** (each beats the next): **Water > Flame > Frost > Nature > Earth > Storm >** back to Water.
- **The pair** (each beats the other): **Celestial <-> Shadow**.

Water 4 pets, Flame 3, Frost 3, Nature 5, Earth 4, Storm 4 (Stormfang among them), Celestial 4, Shadow 3. The
Pet Index has a small **Elements** card that shows the wheel.

## Pet Index

Open it with the **Index** tile. On the left one tile per rarity group with your progress ("3/6"); in the middle
the group's pets (pets you have not found yet are black `???` silhouettes); on the right a detail card with the
pet's rarity, element (with "Strong vs / Weak vs"), role, stats and special attack, and for Stormfang the
owner's artwork as a banner. Every pet you ever win counts as discovered. The footer shows "Unlocked: x/30".

Discover every pet of a group and press **CLAIM** for its reward (once per group; a red `!` on the group tile
means a reward is waiting):

| Group | Common | Uncommon | Rare | Epic | Legendary | Mythic | Secret |
|---|---|---|---|---|---|---|---|
| Reward (Cloud Tokens) | 50 | 120 | 300 | 800 | 2,000 | 5,000 | 10,000 |

## Items

Bought in the shop for cloud tokens, carried up to 5 of each, used on keys `1`-`4` during a climb (they do nothing
in the lobby or during the intro countdown). Slot 4 is a locked placeholder for a future item.

| Slot | Item | Price | What it does |
|---|---|---|---|
| 1 | **Heal Cloud** | 30 | Heals 40 % of your max health. |
| 2 | **Shield Bubble** | 45 | Nothing can hurt you for 8 seconds. |
| 3 | **Phoenix Feather** | 150 | Revives the nearest downed teammate at 50 % health (only used up if someone was revived). |

## The screen

Nothing the game says appears in the middle of the screen. All text follows one readability rule: it is
designed for a 1080p screen (body text 18 px or more, buttons 20 px or more), scales with your screen height and
never drops below 14 px on a phone.

- **Left, vertically centred: the menu** of six square tiles: Inventory, Pets, Index, Shop, My Spot, Stats.
  Windows you open are centred on purpose (you asked for them) and close with Esc, the red X or gamepad B.
- **Top-left:** party panel in the lobby (portal, countdown, members, the **Leave** button), match panel
  (difficulty, timer, checkpoints, team) in a climb. The tutorial card sits below it.
- **Bottom-left:** your **Cloud Tokens** (big number with K / M), and under it the **health and stamina card**:
  a heart badge with a thick health bar (it flashes and shakes when you are hit and pulses when you are low), a
  lightning badge with the stamina bar, and the dash ring that sweeps while dash recharges. NPC dialogs open
  just above it.
- **Right: toasts** stack at the top-right, and the compact result card shows up at the right edge after a
  climb. **Bottom-centre:** the item hotbar (1-4).
- On phones the HUD moves up to clear the thumbstick, and on short landscape screens the token counter moves to
  the top-right.

## Developer tools (owner only)

The game's owner gets a small **DEV** tile (bottom-right corner on a PC, just above the thumb buttons on a
phone) and a few chat commands, to try everything quickly while testing. Nobody else sees the tile, and the
server checks the permission again on every single command, so other players cannot use them.

**Who counts as a developer** (`Config.Dev` in `src/shared/Config.lua`):

- the owner of the game (for a group game: the group's owner),
- the extra Roblox UserIds listed in `Config.Dev.Admins`,
- and **everyone while playing in Roblox Studio** (`Config.Dev.AllowInStudio`), so the tools work in any Studio
  test, even in a place that is not published yet.

**The DEV panel.** Click or tap the DEV tile to open the "Developer tools" panel on the right edge:

| Button | What it does |
|---|---|
| **Give all pets** | One copy of every pet you do not own yet (Secret pets too); every pet counts as discovered, so the Pet Index fills up and its rewards can be claimed. |
| **+1M tokens** | Adds `Config.Dev.GrantTokens` Cloud Tokens (1,000,000). |
| **Restart tutorial** | Plays the tutorial again from step 1. Its rewards are not paid a second time. |
| **Skip tutorial** | Ends the tutorial (without its finish reward). |
| **Evolve every pet** | Plays every pet's evolution animation one after another in front of you (`/evolve all`). |
| **Show all pets** / **Show evolved pets** / **Show Evolved II pets** | Lines up every pet at that stage in front of you (`/pets`, `/pets 1`, `/pets 2`). |
| **Clear pet show** | Removes the showcase pets and stops an evolution (`/clearpets`). |
| **Reset my data** | Back to a brand-new player: tokens, pets, items, stats, Pet Index progress and rewards are wiped, and the tutorial starts again as for a new player. Tap once ("Are you sure?"), then tap again to confirm. Not during a climb. |

Close it with the red X, `Esc` or gamepad B. Every change answers with a "DEV: ..." toast.

**Chat commands** (type them in the game's chat while playing: click the chat bubble at the top left of the game
view or press `/`; not case-sensitive). Not in Studio's command bar at the bottom of the Studio window: that box
runs Lua code and the game never sees what you type there.

| Command | What it does |
|---|---|
| `/allpets` | Same as Give all pets. |
| `/tokens` or `/tokens 50000` | Adds tokens: 1,000,000 by default, or the amount you type (`50000`, `50,000`, `50k` and `1m` all work; at most 100,000,000 at once). |
| `/reset` | Same as Reset my data (no confirmation, so type it carefully). |
| `/tutorial` | Same as Restart tutorial. |
| `/skiptutorial` | Same as Skip tutorial. |
| `/pet <name> [stage]` | Builds that pet in front of you: stage `0` normal (the default), `1` evolved, `2` second evolution (Epic pets and up). The name or a unique part of it is enough, any case: `/pet cloudy 2`, `/pet Pebble Pup`. Each new pet stands beside the last one. |
| `/pets [stage]` | Every pet lined up in rows in front of you: `/pets` (normal), `/pets 1` (all 30 evolved), `/pets 2` (the 13 second evolutions). |
| `/evolve <name> [stage]` | Plays that pet's evolution animation in front of you: with no stage its whole line (normal -> evolved, then -> second evolution for Epic pets and up), `1` only normal -> evolved, `2` only evolved -> second evolution. |
| `/evolve all [stage]` | Every pet's evolutions one after another (all 43 take about 4 minutes; `/evolve all 2` plays just the 13 second evolutions). |
| `/clearpets` | Stops an evolution and removes the showcase pets. |
| `/devhelp` | Two toasts listing the commands. |

The pet showcase (`/pet`, `/pets`, `/evolve`, `/clearpets`) is built on your own screen only: other players do not
see it, nothing is saved and your pets are not touched. The evolution animation is
`src/client/Controllers/EvolutionFx.lua` (the pet charges up and spins in a pillar of light over a ring of runes,
bursts into a flash and the evolved pet pops out; the second evolution gets a double ring and more sparks), ready for
a real "evolve" button later.

At most 4 commands every 2 seconds. Every command is written to the Output window as `[NimbusClimb][Dev] ...`.
Changes are saved like normal progress (a reset lasts), so use them on a test account or in Studio when you want
to keep your real progress.

**Settings** (`Config.Dev`):

| Setting | Default | Meaning |
|---|---|---|
| `Enabled` | `true` | Master switch. `false` turns the tools off for everyone, the owner included: use it to see the game exactly as a normal player does. |
| `AllowInStudio` | `true` | Everyone is a developer in Studio. With `false`, only the owner and the Admins get the tools in Studio too. |
| `Admins` | `{}` | Extra UserIds allowed in the live game, e.g. `Admins = { 12345678, 87654321 }`. |
| `StudioAutoGrant` | `false` | `true`: every Studio test starts with every pet and `GrantTokens` tokens. |
| `GrantTokens` | `1000000` | Tokens added by the button, by `/tokens` without a number and by `StudioAutoGrant`. |
| `MaxTokensPerCommand` | `100000000` | The most one `/tokens` command can add. |

## Coming next

- **Phase 2, tycoon homes:** claim a plot at its gate, then build it up with buy pads: cloud presses that make
  **Cash**, a pet garden for Economy pets, a kitchen to feed pets, a gym, a vault, a house from Cottage to Sky
  Castle, decor, and **Prestige**. Gems, gem roulettes and the Secret roulette at the Storm Altar.
- **Phase 3, pet battles:** a Battle Arena with boss raids, PvP duels, a Trial Portal with 30 levels of NPC
  teams, and on-screen Attack / Retreat / Special controls. Elements and special attacks come into play here.

## Rebuilding the place file

`play/NimbusClimb.rbxlx` is generated from `src/`; never edit it by hand. After changing code, rebuild it from this
folder with [Rojo](https://rojo.space) 7.7.1:

```bash
rojo build default.project.json -o play/NimbusClimb.rbxlx
```

It contains only the three script containers below (plus the lighting technology); the village is built by the
scripts when the game starts.

| Folder | Becomes |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

## Game icon and art

The icon is the Cloudy Dragon on a sky background: `branding/icon-512.png` is the file to upload to Roblox
(`icon-1024.png` and the source `icon.svg` are there too). It is placeholder-quality vector art; see
`branding/README.md` for the upload steps, design notes and how to replace it. The Stormfang artwork the
in-game pet and the Storm Altar are based on is in `branding/stormfang-*.png` / `.webp`.

## Tests

```bash
pip install lupa            # once (also needs Python 3 and Node 18+; npm packages install on first use)
tools/run_checks.sh         # everything, about 10 minutes
tools/run_checks.sh --quick # shorter smoke test (fewer layout seeds), about 7 minutes
tools/run_checks.sh --static   # only the fast checks
```

The script exits non-zero if anything fails and runs three steps:

1. **`tools/syntax.py`**: every `.lua` file must parse as plain Lua 5.1 (no Luau-only syntax).
2. **`tools/check.mjs`**: static analysis (undefined globals, deprecated APIs, raw fonts, bad `Instance.new`,
   missing `require`s, and the public API listed in `tools/contract.json`).
3. **`tools/smoke.py`**: loads the real modules into a Roblox mock (`tools/robloxmock.lua`) and plays the game
   (about 4,000 checks): 5 difficulties x 300 generated courses audited (reach, headroom, cannons, tokens), full
   matches (victory, defeat, timeout, leaving, concurrent slots), portal lock-in, damage and the fall rule,
   hazards, home plots, pets, elements, roulettes, items, the Pet Index, the tutorial, NPCs, the Storm Altar, the
   developer tools, saving (also during DataStore outages), and the whole client UI including the readability rule
   and the "nothing in the middle of the screen" rule on desktop and phone sizes. Handy flags: `-v`,
   `--only match_victory,damage_rules`, `--list`, `--seeds N`, `--strict`.

The mock is not a physics engine (characters do not walk, moving platforms are not simulated), so test the feel
in Studio too. To look at the art and the UI without Studio, `tools/render_model.py` draws any pet, the village,
the Storm Altar or the sky dragon to a PNG, and `tools/render_gui.py` draws the real UI at any screen size (see
`tools/README.md`).

## Project layout

```
default.project.json   Rojo project           play/NimbusClimb.rbxlx   ready-made place file
Start-Rojo-*           one-click launchers    branding/                game icon + Stormfang art
tools/                 syntax check, static analysis, smoke test (see "Tests"), model and GUI renderers
ARCHITECTURE.md, ARCHITECTURE_V2.md, ARCHITECTURE_V3.md   module contracts (the newest wins where they differ)

src/shared   Config (every number)  Theme  Util  Remotes  PetCatalog  ItemCatalog  PetBuilder  Voxel (voxel
             sculpting kit)  TutorialSteps  NpcDialog
src/server   Main.server.lua; Services: Lighting, LobbyBuilder, StormAltar, Player, Data, Damage, Token, Hazard,
             Course (layout + builder), Match, Portal, Spot, Pet, Item, Index, Tutorial, Npc, Dev
src/client   Main.client.lua; State; UI/CloudUI; Controllers: Movement, Hud, DamageFx, Notify, Menu, Hotbar,
             Pet, TokenFx, Index, Tutorial, Npc, SkyDragon, Showcase, Dev
```

The **server is authoritative** (health, tokens, pets, items, checkpoints, matches, the Pet Index, the tutorial,
developer commands); clients only do input, movement feel, UI and purely visual animation (pets, tokens, NPCs,
the sky dragon). Behaviour is attached with `CollectionService` tags (`Config.Tags`). Every tunable number,
including roulette prices and odds, Index rewards, elements, difficulties and physics, lives in
`src/shared/Config.lua`.

Have fun climbing!
