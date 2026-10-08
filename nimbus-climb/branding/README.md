# Nimbus Climb - game icon (the Cloudy Dragon)

The game icon shows the **Cloudy Dragon**, the Mythic mascot pet (`cloudy_dragon` in `PetCatalog`), floating in a
sky with a golden cloud token.

| File | What it is |
|---|---|
| `icon.svg` | The source artwork, 1024 x 1024 viewBox, plain SVG (shapes, gradients, clip paths; no fonts, no images, no scripts). |
| `icon-512.png` | 512 x 512 PNG, opaque, about 215 KB. **This is the file to upload to Roblox.** |
| `icon-1024.png` | 1024 x 1024 PNG, opaque, about 630 KB. For stores, social posts, thumbnails made later, or future re-use. |

## Please read: this is placeholder-quality art, not commissioned art

Be clear-eyed about what this is. The icon is a **hand-built vector illustration**: it was written as SVG
geometry (circles, ellipses, paths, gradients) by an AI coding assistant and rendered to PNG with headless Chromium.
No artist painted it, no stock art, tracing, or AI image generator was used, and it contains no text, so there are no
font or licensing questions. It was checked at 1024, 512, 256 and 128 px and reads clearly even at 128 px
(round white head, big glossy eyes, gold horns, cloud wings, golden token).

It is cute and clean, but it is still a programmer's drawing. If the game finds an audience, the owner may want to
**replace it with commissioned art** from an illustrator. Nothing in the game code depends on this file, so swapping
it is safe at any time (see "Replacing the icon" below).

Design notes (so a commissioned artist, or a future edit, stays on brand):

- Dragon: cloud-white head, sky-blue body and tail, cream belly, small gold horns, big dark-navy glossy eyes with sparkle
  highlights, pink cheeks, cloud wings spread, cloud-puff tail tip. These match the in-game pet colours
  (Primary 236,244,255, Secondary 150,196,240, Eye 30,40,90, gold horns, "Cloud" wings).
- Thick dark-navy outline (`#161d4d`) and glossy highlights, in the chunky "Pet Simulator" style made cloudier.
- Calm sky gradient (deep blue at the top to pale cyan at the bottom), soft light rays, a foreground cloud bank.
  Deliberately not blinding white or neon, in line with the v2 palette goals.
- Golden cloud token = the in-game currency (cloud tokens).

## Uploading the icon in Roblox Creator Hub

You need to be the owner of the experience (or have edit permission on it), and the experience must already exist on
Roblox (in Studio: **File > Publish to Roblox**, once).

1. Open <https://create.roblox.com/dashboard/creations> and sign in.
2. Under **Creations**, click the **Nimbus Climb** experience (use the **Experiences** filter if you have many items).
3. In the experience's left-hand menu open **Basic settings** (in some layouts it sits under **Settings**, or on the
   experience's **Overview** page; use the page search if you cannot find it).
4. Scroll to the **Icon** section (also labelled *Experience icon*).
5. Click **Upload** (or the **+** / "Replace" button if an icon already exists) and choose
   `branding/icon-512.png` from this folder. Roblox wants a square image; 512 x 512 is the recommended size.
6. Crop/confirm if the dialog shows a preview, then press **Save** (top-right of the settings page).
7. New images go through Roblox's automatic moderation first. The icon shows as *pending* and usually appears within
   minutes, occasionally up to a day. Refresh the experience page to check.
8. When you are ready for other players to find the game, also set the experience to public (look for the
   **Access** / **Privacy** setting in the same settings area). An icon uploaded earlier simply waits for that.

Notes:

- The **icon** is the small square picture next to the experience name. The wide **thumbnails** (16:9, 1920 x 1080,
  shown on the experience page) are a separate section; no thumbnails are included here. `icon-1024.png` can be
  used as a starting point for one.
- The Creator Hub menus are renamed from time to time. The names above were written from the project's design spec and
  from memory of the site; the text could not be checked against the live Creator Hub from the build environment, so
  if a label differs, look for whichever section is called Icon / Experience icon on the experience's settings page.
- Roblox may show the icon with rounded corners or smaller than 128 px in some places. All important parts of the art
  sit well inside the frame, so nothing important is cropped.

## Replacing the icon

- **With commissioned art:** deliver a square PNG, at least 512 x 512 (1024 x 1024 preferred), opaque background,
  important content inside the central ~85%, and no small text (it must stay readable at 128 px). Save it over
  `icon-512.png` / `icon-1024.png` (or add new files) and re-upload using the steps above.
- **Editing this SVG:** open `icon.svg` in a vector editor (Inkscape, Figma, Affinity, Illustrator) or a text editor.
  It has a comment per layer group (background, wings, tail, body, horns + crest, head, token). The puffy shapes are
  unions of circles that are drawn twice (a thick navy copy under a coloured copy), so move a circle in both places
  or edit the defs entry that both copies reference (`#wing-s`, `#head-s`, ...).

## Re-rendering the PNGs

Any SVG renderer works (Inkscape, `rsvg-convert -w 512 icon.svg -o icon-512.png`). The files here were rendered with
the pre-installed Chromium through Playwright (the browser is already present, do not run `playwright install`):

```js
// render.mjs  (run with: node render.mjs)
import { createRequire } from "module";
import fs from "fs";
// Playwright is installed globally here; adjust the path (or use a plain import) if yours is elsewhere.
const { chromium } = createRequire("/opt/node22/lib/node_modules/")("playwright");

const svg = fs.readFileSync("branding/icon.svg", "utf8").replace(/<\?xml[^>]*\?>/, "");
const browser = await chromium.launch({
  executablePath: "/opt/pw-browsers/chromium",   // PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
  args: ["--no-sandbox"],
});
for (const size of [512, 1024]) {
  const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
  await page.setContent("<!doctype html><style>html,body{margin:0;background:#000}svg{display:block;width:" +
    size + "px;height:" + size + "px}</style>" + svg);
  await page.screenshot({ path: "branding/icon-" + size + ".png", clip: { x: 0, y: 0, width: size, height: size } });
  await page.close();
}
await browser.close();
```

Each size is rendered from the vector at its own resolution (not scaled down from the 1024 file), so the 512 px
version has crisp outlines. Keep both PNGs under 1 MB.
