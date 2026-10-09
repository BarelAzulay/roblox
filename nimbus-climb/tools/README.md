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
