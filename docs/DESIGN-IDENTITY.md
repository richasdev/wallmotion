# Wallmotion monitor-and-waves identity · issue #181

Wallmotion is identified by the thing it controls: a desktop monitor whose screen is full of flowing wallpaper. The display's graphite frame, rounded corners and stable stand preserve a clear object silhouette. Cyan and teal waves with a warm coral ribbon add color and depth without a letter monogram. The waves fill the display rather than sitting as a small decorative underline.

## Asset hierarchy

The Dock icon is a static 1024px composition on a mineral tile, with native-sized raster slots generated directly from SVG. The in-app icon is the same composition drawn by SwiftUI Canvas, excluding exterior Dock padding and shadow. At 16px both simplify details and strengthen the bezel. The menu symbol reduces the composition to a monitor outline, stand and one wave, drawn once as a cached AppKit template. System tint supplies light/dark contrast; the menu never uses a multicolor miniature.

The release source is `resources/branding/wallmotion-icon.svg`; regeneration and exact palettes are documented in `resources/branding/README.md`. Historical concept files are not runtime resources. `BrandLogoView` already delegates to `WallmotionBrandIcon`, so replacing the shared component updates the sidebar without an additional identity implementation. `WallmotionMenuIcon.image` updates the menu through the existing application wiring.

## Native interface boundaries

Wallmotion keeps system typography for titles, controls and settings; labels use native sizes and sufficient contrast. The artwork palette does not replace control/status semantics. The existing macOS 14 deployment target and availability-guarded native glass stay unchanged. Icon shading is static artwork, separate from the application’s live system material.

## Performance and accessibility

The artwork has no timer, animation, live media preview, remote asset or runtime SVG dependency. The native icon uses a fixed set of vector fills; the menu image is cached. Decorative in-app artwork remains hidden from accessibility, while the existing product label and menu accessibility name identify Wallmotion. Color carries the artwork's character; the monitor silhouette remains usable in monochrome. Interface controls retain their separately measured semantic ink and native glass behavior.

## Review evidence

Validation includes reproducible generation hashes, ten ICNS slot dimensions/transparency, actual 16/32/128/512px and full 1024px inspection, optical 16px variants, black/alpha menu masks and native SwiftUI/AppKit renders. No energy improvement or physical multi-monitor/HDR calibration is inferred from asset-only checks. Final PR review must use the exact commit SHA and the project's independent reviewer/guarded merger process.
