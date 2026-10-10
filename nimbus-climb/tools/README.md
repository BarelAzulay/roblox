# tools

Checks and helpers for Nimbus Climb. The test pipeline (`run_checks.sh`, `syntax.py`, `check.mjs`, `smoke.py`) is
described in the "Tests" section of the main `README.md`.

## Model renderer: see the voxel art without Studio

`render_model.py` builds a model with the **real** game modules (inside the same lupa + `robloxmock.lua` world that
`smoke.py` boots, via `dump_model.lua`) and draws it with a small numpy + Pillow rasteriser: orthographic views,
flat Lambert shading with a key light from the upper front-left, Neon glowing, Glass/transparent parts blended,
thin outlines on silhouettes. Needs `lupa`, `numpy` and `Pillow`. A pet takes about a second, the whole lobby a few.

```sh
python3 tools/render_model.py pet:stormfang -o stormfang.png          # 2x2 sheet: front, 3/4, side, back
python3 tools/render_model.py pet:cloudy_dragon:Low -o low.png        # Low detail (followers of other players)
python3 tools/render_model.py species:Fox -o fox.png                  # a species with a neutral sample look
python3 tools/render_model.py --grid -o pets.png                      # every catalog pet, labelled (pets:Low, species)
python3 tools/render_model.py token:golden --views front,side -o coin.png
python3 tools/render_model.py skydragon --views side,top -o dragon.png
python3 tools/render_model.py lobby --views threequarter,top --size 1400 -o lobby.png
python3 tools/render_model.py lobby --box -125,270,-125,125,360,125 --views top -o plaza.png   # crop (world studs)
python3 tools/render_model.py lobby+npcs+storm-altar --views top -o village.png
python3 tools/render_model.py module:server/Services/LobbyBuilder:Build -o any.png   # generic; add :lobby to pass LobbyInfo
```

* Targets: `pet:<id>[:High|Low]`, `species:<Species>[:High|Low]`, `lobby`, `npcs`, `storm-altar`, `skydragon`,
  `token[:golden]`, `module:<path>:<func>[:lobby]`, several joined with `+`, or a `.json` dump from `--json`
  (`storm-altar` needs `server/Services/StormAltar.lua`; `npcs` and `storm-altar` build the lobby first).
* Views: `front` looks the model in the face (a pet's LookVector), `side` at its right flank (face to the right),
  `back`, `left`, `threequarter`, `top` (front at the bottom). All views of a sheet share one scale.
* Output: the PNG (part count in the bottom-right corner) plus the part count and bounding box on stdout.
  `--json dump.json` keeps the part dump (position, rotation matrix, size, colour, material, transparency, shape);
  `--dump-only` skips the drawing. Other flags: `--size`, `--cell` (grid), `--ss` (supersampling), `--outline`,
  `--echo` (show the game's print/warn output).
* Balls and cylinders are drawn as polyhedra and textured materials (Grass, Cobblestone...) as flat colour, so the
  render shows shapes, colours and proportions, not Roblox's exact lighting.

## GUI renderer: see the 2D UI without Studio

`render_gui.py` boots the **real** client (`Main.client.lua` and every controller) in the same lupa + `robloxmock.lua`
world `smoke.py` uses, at the screen size you ask for, drives it into a scenario with the fake server events the smoke
tests send (`dump_gui.lua`), dumps every visible GuiObject of PlayerGui and draws the dump with Pillow. The mock lays
out UDim2 / AnchorPoint / AutomaticSize / UIListLayout / UIGridLayout / UIPadding / UIScale / UIAspectRatio /
UISizeConstraint; the renderer measures text with real fonts (the mock's layout engine is handed the same metrics, so
auto-sized pills fit their text) and draws ScreenGuis by DisplayOrder, siblings by ZIndex, rounded corners,
UIStrokes (box and text), UIGradients, legacy borders, TextScaled + UITextSizeConstraint, wrapping, truncation,
rich-text colours, the typewriter limit, colour emoji, Rotation, CanvasGroups, clipping and scroll bars. A dump takes
well under a second, a 1080p render one to three seconds.

```sh
python3 tools/render_gui.py lobby -o lobby.png                       # idle lobby HUD at 1920x1080
python3 tools/render_gui.py match --size 1280x720 -o match.png       # match panel, damaged HP bar, drained stamina
python3 tools/render_gui.py menu:Index:Mythic -o index.png           # a window (Inventory, Pets, Index, Shop, Stats)
python3 tools/render_gui.py tutorial:3 --grid -o tutorial.png        # 1920x1080, 1280x720, 390x844, 844x390 in one sheet
python3 tools/render_gui.py match --crop 0,920,420,160 --scale 3 -o hp.png   # zoom into the HP / stamina bars
python3 tools/render_gui.py npc --mark-small --boxes -o npc.png      # red frames on small text, every box outlined
python3 tools/render_gui.py gallery -o gallery.png                   # renderer check: one cell per feature, known values
```

* Scenarios: `lobby`, `title` (title card up), `match` / `match:hit` (a quarter second after a hit), `countdown`,
  `party` (portal party panel), `results`, `menu:<Window>[:<Tab or Index group>]`, `tutorial[:<step>]`, `npc[:<n>]`,
  `dev` (owner panel), `toasts`, `gallery`, or a `.json` dump written earlier with `--json`. `--list` prints them.
* Screen: `--size WxH` (default 1920x1080). The smaller side <= 500 px boots a touch device (RUN / DASH buttons,
  raised HUD); `--touch` / `--no-touch` override (use `--touch` for tablets). Roblox's top bar (the 58 px inset) and,
  on touch devices, its thumbstick and jump button are sketched as faint ghosts (`--no-chrome` hides them).
* Output: the PNG plus a report on stdout: object and text counts, the game's script errors, every text under the
  readability floor (15 px on screens >= 1000 px tall, 14 px below) and the **smallest on-screen text** with its path.
  `--json FILE` keeps the dump (absolute boxes, ZIndex, colours, corner radius, strokes, gradients, text properties).
  Other flags: `--bg lobby|grey|sky|dark`, `--ss` (supersampling), `--no-labels`, `--echo`, `-v` (font mapping, warns).
* Fonts are substitutes found with `fc-list`: a bold rounded sans when installed (Fredoka, Nunito, Varela Round...),
  otherwise Inter, then DejaVu Sans; symbols fall back to DejaVu, emoji to Noto Color Emoji. Glyph shapes and widths
  differ a little from Roblox's FredokaOne / Gotham / Builder Sans, so a text that only just fits (or only just gets
  truncated) deserves a look in Studio. ImageLabels and ViewportFrames are labelled placeholders (a viewport shows a
  blob tinted by ImageColor3, so Index silhouettes come out black); animations are frozen at the moment of the dump.
* `tools/smoke_polish_guitool.lua` (smoke scenario `client_gui_dump`) checks the dumper against the live client UI
  and the gallery.
