# Wallmotion brand assets

The active mark is a graphite desktop monitor filled edge to edge by broad coral, cyan and teal waves. A visible stand makes the silhouette recognizable without text. A pale mineral tile separates the display from both light and dark Dock backgrounds. Historical `wallmotion-concept-*` files are exploration references, never release inputs.

## Active sources

- `wallmotion-icon.svg`: editable 1024px Dock/Finder artwork with a 100px outer margin. Three filled wave layers occupy the full display; highlights and shadows are baked into the static asset.
- `wallmotion-mark.svg`: standalone monochrome monitor/one-wave symbol (`currentColor`).
- `wallmotion-menubar-template.svg`: the same monitor/one-wave geometry in black and alpha, at 22px.
- `../../Sources/Wallmotion/WallmotionSymbol.swift`: native `WallmotionBrandIcon(size:)`, `WallmotionMark` and cached `WallmotionMenuIcon.image`. The in-app Canvas uses the same monitor and wave coordinates, without the Dock margin or exterior shadow. It performs no image reads, SVG parsing, media playback or animation.

Full-color palette: mineral #F0F7F6/#DCEBEA/#B9D0D1, graphite #46545A/#25363E/#16262E, coral #FFD2A0/#FF8C83/#DE527A, cyan #9DFFF0/#34E0D6/#1397AC and deep teal #1FB6B9/#073C63. Interface theme colors are separate from icon artwork.

The 16px optical variant thickens the monitor bezel and removes subpixel highlights, status light, rim and shadows. It preserves all three broad wave layers. The native in-app icon applies the same small-size bezel adjustment. The menu symbol uses a clear outline and one wave, not miniature colored artwork, so the operating system can supply the appropriate tint.

## Regeneration

On macOS, install the build-time renderer (`brew install librsvg`), then run:

```sh
python3 scripts/build-brand-assets.py
```

The script invokes `rsvg-convert` and system `iconutil` through argument arrays, builds in a private temporary directory and removes intermediates. Every iconset slot is rendered directly from vectors, including 1024px; no upscaling. It synchronizes `resources/AppIcon.icns` (release input) and `resources/branding/AppIcon.icns`, and exports the PNG preview plus 22/44px menu templates. The application gains no runtime dependency.

Consecutive runs with librsvg 2.62.3 and the host iconutil are byte-identical. Changes to renderer versions may affect antialiasing/compression and require visual review.

## Validation · 2026-11-08

Reviewed actual 16/32/128/512px exports, with 5× nearest-neighbor inspection of the smallest sizes, plus the full 1024px source preview. All ten ICNS slots have correct dimensions and transparent outer corners. The small icon retains a recognizable monitor/stand and colored wave bands. Native SwiftUI Canvas exports at 16/28/128pt and the cached 22pt template render successfully using Swift 6 and `-j 2`; menu PNG/native masks contain black RGB with alpha and matching visible bounds at 2×. The native template is marked `isTemplate == true` for system appearance.

These checks validate assets and components. Integrated library/menu/release verification belongs to the application PR. Remote CI billing remains tracked in #11; local validation is not represented as remote CI success.
