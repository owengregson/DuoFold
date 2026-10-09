# Duo Fold README system

Everything that builds the GitHub README for Duo Fold: the Markdown, the glass-styled SVG artwork, and the scripts that generate it. Hand-edit nothing under `assets/`; change a generator and re-run it.

## Layout

```
README.md                   the deliverable, drop at the repo root with assets/
assets/                     everything README.md references
  hero.svg                  animated hero (lean + frost + gauge)
  headers/<slug>-{dark,light}.svg   numbered glass section pills, swapped by <picture>
  buttons/{dmg,releases}-{dark,light}.svg
  diagrams/{presets,anatomy,curve,haptics,engineering,pipeline}.svg
  divider-{dark,light}.svg
  menu.png                  settings screenshot from the app repo (assets/menu.png)
full/*.svg.txt              pristine copies of the animated SVGs (see "Caveat")
src/
  gen-world.js              draws the fake screen the hero blurs → world.svg, world.jpg.txt, world-blur.jpg.txt
  gen-hero.js               hero.svg: perspective lean (GlassLean geometry), frost bands, gauge card
  gen-assets.js             every other SVG: headers, buttons, divider, five diagrams
  build-zip.js              packs README.md + assets (uses full/ for animated files)
  icon-ic08.png …           app icon extracted from Resources/AppIcon.icns (ic08 = 256 px is the one used)
README Preview.dc.html      GitHub-dark mock of the README for previewing in the design tool
```

## Regenerating

Scripts are plain async JS written for the design tool's `run_script` sandbox (helpers `readFile`, `readFileBinary`, `saveFile`, `ls`, `readImage`, `createCanvas`, `log`). Run one with:

```js
const src = await readFile('readme/src/gen-assets.js'); await eval(src);
```

- Hero: run `gen-world.js` (twice the first time; `readImage` only sees committed files), then `gen-hero.js`. Set `var FREEZE = 0.5` before eval to write a single still frame (`src/hero-t0.5.svg`) at that fraction of the loop for inspection.
- Diagrams/headers/buttons: `gen-assets.js`. Set `var OUT_DIR = 'readme/_check/'` to write elsewhere and compare before overwriting.
- Package: `build-zip.js` → `DuoFold-README.zip`. `var ZIP_SYSTEM = true` → `DuoFold-README-System.zip` (this whole folder).

## Caveat: the project strips SVG animation

Saving an `.svg` into the project removes `<animate>` elements and embedded images. That is why every animated graphic is saved twice: `assets/<name>.svg` (reduced, for the preview) and `full/<name>.svg.txt` (pristine). `build-zip.js` always packs the `full/` copy. The preview (`README Preview.dc.html`) swaps the pristine copies in at runtime via `data-art` attributes.

## Design system

Colours come from the app icon: night indigo `#060B2E → #2A1E78`, magenta `#FF5FA2 / #D63F8C`, peach `#FFB08A`, cream `#FFE2C4`, violet `#6F5BFF`. Lavender `#B4ABE6` is the secondary text colour inside diagrams. Every diagram is 860 px wide on the `world()` backdrop with `panel()` glass cards: blurred backdrop, 5–8% white tint, top sheen, gradient rim. Type is the system stack (SF Pro on macOS); mono labels are uppercase with letter-spacing.

## Where the numbers come from

All curves and values are lifted from the app source, not invented: `LidEffectRamp` (start/span, soft lean cap), `BlurGradient` (blur ∝ height^2.25, dim reach), `FrostBandLayout` (bands), `EffectPreset` (the five presets), `HapticPattern` (tap stops), `GlassLean`/`DepthGeometry` (perspective), `LidWake`, `LidAngleEstimator`, `WindowServerBlur`, `LidPicturePolicy` (technical design cards). When the app changes, update the constants near the top of each generator.
