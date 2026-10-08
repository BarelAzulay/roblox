# Nimbus Climb

> *Climb the storm. Together.*

A cosy, co-op **cloud parkour** hobby game for Roblox. You wake up in a floating cloud village, step into a
glowing **portal** with up to three friends, and get flown to a freshly generated **sky course** that you
have to climb as a team: dash across gaps, dodge spinning bars and lightning, hold pressure plates so your
friends can cross, share checkpoints, lift each other back up and collect **cloud tokens** floating over the
trickiest steps.

Everything is built from plain parts and particles (no asset ids, no toolbox models), and every piece of
text goes through one small `Theme` module, so the whole game shares the same rounded, friendly fonts.

## Highlights

- **Cloud village lobby** - a big puffy plaza, floating islands and bridges, a rainbow arch, lanterns, ponds,
  fireflies, a welcome sign and a "How to play" board. The lobby is safe: nobody can get hurt there.
- **Three portals = three difficulties** - *Soft Breeze*, *Gale Force*, *Thunderstorm*. Standing on a portal
  pad joins its party (1-4 players); a countdown launches the match.
- **Procedural courses** - every match builds a new course from a seed, validated against reach-ability rules
  (run gaps, dash gaps, jump heights, no overlapping platforms) before it is built.
- **Co-op rules** - shared checkpoints, downed teammates that can be revived, pressure-plate bridges that need
  somebody to stand on the plate, and a team result at the end.
- **Hazards** - spinning bars, storm clouds, lightning zones with a red warning disc, vanishing clouds,
  moving clouds, bounce pads.
- **Cloud tokens** - golden tokens floating over risky steps. They are saved between visits (DataStore) and
  shown on the leaderboard.
- **Health, stamina and damage** - a custom health bar, damage numbers, screen flash and camera shake. Health
  never reaches zero in a match: a lethal hit puts you in the *downed* state until a teammate reaches the next
  checkpoint.

## Controls

| Action | PC | Mobile | Gamepad |
|---|---|---|---|
| Move | `W` `A` `S` `D` | thumbstick | left stick |
| Jump | `Space` | jump button | `A` |
| Run (uses stamina) | hold `Left Shift` | **RUN** button (toggle) | `L3` |
| Dash (also in the air) | `Q` | **DASH** button | `B` |
| Leave party / match | on-screen **Leave** buttons | same | same |

## Open it in Roblox Studio (Rojo)

The repository is a [Rojo](https://rojo.space) project (`default.project.json`):

| Folder | Becomes |
|---|---|
| `src/shared` | `ReplicatedStorage.Shared` |
| `src/server` | `ServerScriptService.Server` |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` |

1. **Install Rojo** - the easiest way is the VS Code extension "Rojo", or install the CLI with
   [Rokit](https://github.com/rojo-rbx/rokit) (`rokit add rojo-rbx/rojo`) or from the
   [releases page](https://github.com/rojo-rbx/rojo/releases). Also install the **Rojo plugin** in Studio
   (Plugins tab -> Manage Plugins, or `rojo plugin install`).
2. **Live sync:** in this folder run

   ```bash
   rojo serve
   ```

   open a new **Baseplate** place in Studio, click **Connect** in the Rojo plugin, then press **Play**.
3. **Or build a place file** and open it directly:

   ```bash
   rojo build -o NimbusClimb.rbxlx
   ```

4. Recommended place settings: *Game Settings -> Security -> Enable Studio Access to API Services* (so saving
   tokens works in Studio) and leave *StreamingEnabled* off. The server script already sets the sky, lighting,
   gravity and the fall-destroy height, so an empty baseplate is all you need: the game places players itself.

To test parties in Studio use **Test -> Clients and Servers** with 2-4 players, then walk onto the same portal.

## How a session works

```
lobby plaza --walk onto a portal pad--> party (1-4 players, countdown 15 s, 4 s once full)
   ^                                        |
   |                                        v
 results screen (10 s) <--- course <--- intro countdown (5 s, frozen) <--- teleport to the start platform
```

* **Portals** - `PortalService` polls the pad zones 5x per second. Stepping off the pad (or pressing *Leave*)
  leaves the party. The first player starts the countdown; a full party shortens it. If all six arena slots are
  busy the party is told *"All sky arenas are busy"*.
* **Matches** - `MatchService` owns the state machine *Setup -> Countdown -> Playing -> Ended*. Each match gets
  its own arena slot far from the lobby (`Config.Match.ArenaOrigin` + slot x `SlotSpacing`), so up to six
  matches run side by side. When it ends, the course, hazards, token watchers and all event connections are
  torn down and the slot is reused.
* **Checkpoints are shared** - the first player to touch checkpoint *n* sets it for the whole team, heals every
  living teammate (35 %) and **revives all downed teammates** on that pad. Falling into the void costs health
  (15 / 22 / 30) and brings you back to the team checkpoint.
* **Downed** - a lethal hit leaves you at 1 HP, frozen and see-through until a teammate reaches the next
  checkpoint (revive = 50 % health). If *everybody* is downed the team loses.
* **Winning** - every living player has to stand on the finish pad. Finished players are parked safely on the
  pad and every finisher gets the win bonus (10 / 20 / 40 tokens). Running out of time (10 / 15 / 20 minutes)
  is a defeat.
* **Reset button** - respawns you at the team checkpoint with 50 % health, no penalty.
* **Co-op gimmicks** - `PressurePlate` + `PlateBridge`: the bridge only exists while a teammate stands on the
  plate. `DashGap`s can only be crossed with a dash (a **DASH!** sign warns you).

## Architecture in one minute

`ARCHITECTURE.md` is the binding contract between all modules (names, argument order, payload shapes).

```
src/shared    Config  Theme  Util  Remotes                (pure data / helpers, used by both sides)
src/server    Main.server.lua                              boots everything in order, each step under pcall
  Services/   LightingService   sky, atmosphere, gravity
              LobbyBuilder      builds the cloud village, returns portals + spawn
              PlayerService     leaderstats, humanoid stats, spawn placement, lobby safety loop
              DataService       DataStore + in-memory cache (tokens), autosave, BindToClose
              DamageService     the only place health changes: i-frames, downed, revive
              TokenService      cloud token parts + collection
              HazardService     animates tagged course parts and damages through DamageService
              CourseBuilder     procedural layout (pure) + part builder
              MatchService      match lifecycle and team rules
              PortalService     parties at the portals
src/client    Main.client.lua                              starts the controllers
  Controllers/ MovementController  run / dash / stamina / mobile buttons
              HudController       health, stamina, tokens, match panel, party panel, countdown
              DamageFx            vignette, camera shake, floating damage numbers
              NotifyController    toasts, results card, other players' dash trails
```

Rules of the road: the **server is authoritative** (health, damage, tokens, checkpoints, match flow); clients
only do input, movement feel and UI. Behaviour is attached with `CollectionService` **tags** (`Config.Tags`)
plus **attributes** for parameters. Server -> client state travels over a handful of RemoteEvents
(`Config.Remotes`: `Notify`, `DamageTaken`, `PartyState`, `MatchState`, `MatchResult`, `DashFx`). All Lua is
plain Lua 5.1-compatible syntax (no Luau-only syntax) so the tooling can parse it with stock parsers.

## Tuning: `src/shared/Config.lua`

Every number lives there. The ones you will touch most:

| Section | What it controls |
|---|---|
| `Physics` | gravity, walk / run speed, jump power, dash speed / duration / cooldown / stamina cost, stamina regen. The course generator derives its maximum jump height and gap lengths from these, so changing them keeps courses fair. |
| `Damage` | i-frame length, downed health, revive / checkpoint heal fractions, void damage per difficulty. |
| `Lobby` | where the village floats (`Origin`), plaza and portal ring radius, the "fell off" height. |
| `Match` | player limits, party / full-party / intro / results countdowns, arena origin, slot spacing, number of concurrent matches, win bonus per difficulty. |
| `Difficulties` | per difficulty: number of stages, steps per stage, gap and rise ranges, platform sizes, hazard and dash-gap chances, tokens per stage, time limit, stars, colour. |
| `Tokens` | DataStore name, autosave interval, token value. |

Adding a fourth difficulty is mostly a new entry in `Config.Difficulties` (plus a damage / bonus entry); the
lobby builds one portal per entry.

## Checking your changes

```bash
pip install lupa            # once: embedded Lua for the syntax check and the smoke test
tools/run_checks.sh         # everything (about 20 s); add --quick for a shorter run
tools/run_checks.sh --static   # only the fast checks
```

`run_checks.sh` runs three things and exits non-zero if one fails:

1. **`tools/syntax.py`** - every `.lua` file must parse as plain Lua (this rejects Luau-only syntax such as
   `+=`, `continue`, type annotations and backtick strings).
2. **`tools/check.mjs`** (Node + [`luaparse`](https://www.npmjs.com/package/luaparse), installed on first use)
   - static analysis: undefined globals (typos, locals used before they are declared), assignments to globals,
   deprecated `wait/spawn/delay`, raw `Enum.Font` outside `Theme.lua`, `Instance.new` with a class Roblox cannot
   create, unknown services, `require` of missing modules, modules that do not `return`, more than 200 locals in
   a function, and the public API from `ARCHITECTURE.md` (`tools/contract.json`).
3. **`tools/smoke.py`** - loads the real modules into a **Roblox mock** (`tools/robloxmock.lua`: Instances,
   datatypes, Enums, signals, a fake clock, Players/Workspace/DataStore/... on `lupa`) and plays the game:
   - generates and audits 200 course layouts per difficulty (gaps, rises, tokens, checkpoints, determinism) and
     prints their stats, builds real courses and inspects the parts, tags and attributes;
   - boots `Main.server.lua`, joins fake players, walks them into portals, runs full matches - victory,
     defeat (everybody downed), timeout, everybody leaves, leaving through the HUD button, reset-button
     deaths, six concurrent matches - and checks damage, i-frames, downing, revives, checkpoints, void,
     tokens, win bonus, hazards (spin bars, storms, lightning, vanishing / moving clouds, bounce pads, plates),
     DataStore saves (also during an outage) and `BindToClose`;
   - verifies every remote payload against `ARCHITECTURE.md`, that every text label uses a Theme font and that
     nothing leaks (workspace, connections, threads, tweens) after the matches;
   - loads the client controllers with a fake `LocalPlayer`, presses run / dash, feeds the HUD synthetic
     payloads and then **replays the exact remote traffic the real server produced**; a second run simulates a
     phone (touch buttons).

   Useful flags: `-v` (list passing checks), `--only match_victory,damage_rules` (`--list` shows all scenario
   names), `--seeds N`, `--strict` (warnings fail), `--strict-members` (reading a property that does not exist
   raises, like Roblox), `--engine lua54`. The mock is deliberately strict where Roblox is (wrong property
   types, `Instance.new("Typo")`, parenting a destroyed instance, `FireServer` on the server ...) but it is not
   a physics engine: characters do not walk, touches are derived from overlapping boxes and moving platforms
   are not simulated. Anything it records as *unknown member* is a hint to check the Roblox API docs, or to
   teach the mock the property in `tools/robloxmock.lua`. Real class and service names live in
   `tools/roblox-api.json`.

## Ideas for next steps

- Sound: footsteps on clouds, wind, thunder, a gentle lobby theme (needs asset ids, which were avoided so far).
- Cosmetics shop in the lobby that spends cloud tokens (trails, hats, dash colours) and a token leaderboard.
- Daily seed: one shared course per day with a best-time board, and ghost runs of friends.
- More hazards: wind gusts that push sideways, rotating platforms, ice clouds, rising storm "lava" that forces
  the team forward.
- Co-op tools: a team rope between players, a boost or shield power-up, emotes and a ping marker.
- Accessibility: colour-blind safe hazard markers, an assist mode with longer i-frames, remappable controls.
- Private servers / invite-a-friend parties and a spectator camera for downed players.
- Real assets (meshes, sounds, decals) once the base game feels good.

Have fun climbing!
