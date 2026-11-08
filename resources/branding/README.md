# Wallmotion brand assets

The active identity is a rounded W over a single teal horizon. The larger central symbol replaces the small corner monogram and fine competing waves, which lost their shape at menu and Finder sizes. Its silhouette is shared by the app icon, in-app mark and monochrome menu symbol. Historical `wallmotion-concept-*` files remain exploration references; they are not release inputs.

## Active sources

- `wallmotion-icon.svg`: editable 1024px Dock/Finder icon, with standard 100px outer margin. Graphite tile, one teal horizon and a pale W; shading belongs to this static artwork, not a runtime blur or animation.
- `wallmotion-mark.svg`: standalone vector symbol (`currentColor`).
- `wallmotion-menubar-template.svg`: black-and-alpha symbol, tinted by macOS. Its viewBox crops to the icon tile, matching the native 22-point template.
- `../../Sources/Wallmotion/WallmotionSymbol.swift`: the matching native `WallmotionMark` shape, `WallmotionBrandIcon(size:)` and cached `WallmotionMenuIcon.image`. Keep the W control points and 78/824 stroke ratio aligned with the vectors. The native menu image is drawn once, marked as a template, and uses no file reads or runtime SVG library.

The in-app icon deliberately has no Dock margin or exterior shadow. At 16px, its W uses a thicker 96/824 stroke and removes the horizon, as does the 16px raster icon. Menu icons keep a transparent ground so macOS supplies appropriate contrast in both appearances.

## Regeneration

On macOS, install the build-time SVG renderer (`brew install librsvg`), then run:

```sh
python3 scripts/build-brand-assets.py
```

The script invokes `rsvg-convert` and the system `iconutil` without shell interpolation. It builds in a private temporary directory, validates tool completion before publishing, and removes its intermediates. There is no added app/runtime dependency. All app-icon PNG slots are rendered directly from vectors at their native size, including the 1024px Retina slot; no upscaling. Both `resources/AppIcon.icns` (release input) and `resources/branding/AppIcon.icns` are synchronized. PNG preview and menu templates are included for inspection and reuse.

Regeneration was byte-identical across consecutive runs with librsvg 2.62.3 and the host macOS iconutil. Tool-version changes may alter antialiasing or PNG compression, so inspect regenerated files before committing.

## Visual validation (2026-11-08)

Reviewed exported iconset at actual 16, 32, 128 and 512px, with nearest-neighbor 4× enlargement of the two smallest sizes. The W remains distinct at 16px; the horizon is retained from 32px upward. Checked 22/44px menu PNGs contain black RGB and alpha only. Verified transparent outer corners and all ten standard iconset slots. A native AppKit rendering of the cached template reports `isTemplate == true`, 22×22 points and identical alpha bounds to its SVG counterpart at the host 2× scale. Swift 6 standalone type-check passed.

This is asset and component validation; integrated library/menu rendering is verified separately by the UI PR. Remote GitHub Actions remains subject to the account billing limitation tracked in issue #11.
