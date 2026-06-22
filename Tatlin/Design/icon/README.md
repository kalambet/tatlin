# Tatlin app icon — parametric master

The icon is **authored as code** (parametric SVG of Tatlin's *Monument to the Third
International* — a leaning double-helix truss cone), not drawn by hand. This keeps the
geometry exact and lets us re-render at any size on demand.

## Files

| File | Role |
|------|------|
| `gen5.py` | **Current generator** — lead candidate. Edit this to iterate the design. |
| `icon5.svg` / `icon5_512.png` | Lead candidate output (constructivist red + black on cream). |
| `gen.py`…`gen4.py`, `icon*.svg/png` | Earlier iterations, kept for history. |

## Render pipeline (all tools already installed)

```bash
python3 gen5.py                                   # writes icon5.svg
rsvg-convert -w 1024 -h 1024 icon5.svg -o out.png # SVG -> PNG at any size
# sips        : resize / format-convert
# iconutil    : .iconset -> .icns
```

## Regenerate the shipped assets

`tower.py` emits the per-slot SVG variants; render them into the catalog with:

```bash
python3 tower.py                                  # writes tower-*.svg + menubar-*.svg
AC=../../Tatlin/Assets.xcassets
# macOS ladder (squircle): 16/32/128/256/512 @1x+@2x -> $AC/AppIcon.appiconset/
# iOS 1024 square: universal / dark / tinted
# menubar PDFs: rsvg-convert -f pdf menubar-idle.svg -o $AC/MenuBarTower.imageset/...
```
(exact rsvg-convert size list is in git history of this folder / the M3.7 commit).

## Status — M3.7 (done 2026-06-22)

- [x] Direction locked: lattice/engineering truss, constructivist red on cream (icon5).
- [x] Full macOS ladder (16→1024 @1x/@2x) rendered into `AppIcon.appiconset`,
      baked Apple squircle with transparent margins.
- [x] iOS 1024 universal + dark + tinted variants wired into the catalog.
- [x] Monochrome **menubar template** PDFs (idle + recording) as `MenuBarTower` /
      `MenuBarTowerRecording` imagesets (`template-rendering-intent: template`),
      driving `AppModel.menuBarIcon`. Processing state keeps SF Symbol `hourglass`.
- [x] Verified: `BUILD SUCCEEDED`, no asset warnings; compiled `AppIcon.icns` confirmed.

### Optional polish (not blocking)
- [ ] **Icon Composer `.icon`** (macOS 26 Liquid Glass layers): the legacy `AppIcon`
      set already renders correctly on macOS 26 (it falls back), so this is an
      enhancement, not a requirement. It needs the Icon Composer GUI (Xcode 26):
      open `tower-mac.svg`, split into back/middle/front layers, export `Tatlin.icon`,
      add to the target, set `ASSETCATALOG_COMPILER_APPICON_NAME` accordingly.
