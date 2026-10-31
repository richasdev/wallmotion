# Shared GIF panorama

Issue #153 extends the existing local-photo panorama to local GIFs. Videos and web
sources remain ineligible. Switching from a GIF selection seeds the shared panorama;
returning to independent mode restores the previous per-display assignments.
The library format is unchanged and GIF panorama selections round-trip through v4.

Each `ImageSurface` receives a slice of one global `PanoramaLayout` in AppKit point
coordinates. Fill, fit, stretch and center use the same global union, including
negative origins, gaps and vertical arrangements. Center uses the maximum connected
backing scale as the shared reference, so mixed-DPI screens cannot independently
resize the same image and break the seam. The source image remains immutable.

The production async admission/decode path is retained. Screens sharing a GIF use
the same `PreparedGIF`, current `NSImage` and `SharedGIFPlayback` clock. Existing
budgets charge the decoded frame payload once by source identity. An occluded
screen stops receiving frames while another visible subscriber keeps the timeline
active. The last inactive subscriber cancels its tick; stop removes subscribers and
budget charges. Topology changes rebuild the slices while reusing the prepared
asset and current image. This does not assert zero GPU copies, total RSS limits or
measured battery savings.

## Evidence

Five AppKit integration tests use a private temporary store and synthetic offscreen
displays on the available physical screen:

- Production preparation decodes a two-frame 4×2 GIF once for two displays, charges
  its 64-byte frame payload once, shares image identity and advances both slices on
  the same clock. Partial/all occlusion, resume and stop follow subscriber policy.
- All four fits keep identical global image geometry across negative origins,
  vertical offsets, screen gaps and mixed 1×/2× backing scales.
- Real AppKit raster captures verify red and blue halves in different screen slices
  while retaining the same underlying image. Optional exports use
  `WALLMOTION_GIF_PANORAMA_SNAPSHOT_DIR`; both PNGs were visually inspected. The
  tiny colored fixture demonstrates cropping, not real-media resolution quality.
- Removing a synthetic monitor changes the remaining slice to the new union,
  closes obsolete windows and retains the single prepared asset/decode.
- The model seeds a GIF panorama asynchronously, persists it, shares fit settings,
  keeps video ineligible and restores independent assignments.

A Core case verifies persisted GIF panorama and rejects local video, remote GIF and
web sources. Existing photo panorama, availability and shared GIF tests remain in
the regression suite. Full validation passed with 50 Rust tests, Clippy with
warnings denied, 35 Python tests, 168 Swift Core tests and 220 AppKit tests (10
opt-in skips). Release and strict ad-hoc signature verification also passed.

Commands: `sh scripts/check.sh`, `swift test -j 2 --filter GIFPanoramaTests`,
`sh scripts/build-app.sh`, `codesign --verify --strict dist/Wallmotion.app`.
GitHub Actions is still blocked by account billing (#11). Physical multi-monitor
alignment, hardware refresh rates, HDR/SDR, animated video panorama and energy
measurements remain unverified under #43 / #8; this closes only the GIF software
scope in #153.
