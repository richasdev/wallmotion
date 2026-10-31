# Native video panorama (#43)

Panorama now accepts local native video and HTTPS native video/HLS, alongside local photos/GIFs. Official web embeds remain ineligible. Existing separate-display assignments and framing remain stored when entering or leaving panorama. No library schema or mode rename is needed: the persisted mode is still spanned.

Each VideoSurface clips a global destination rectangle calculated with PanoramaLayout and the AVPlayerItem presentationSize, including track rotation. Its native AVPlayerLayer uses resize because global fit/fill/center/stretch has already been applied once. Negative screen origins, gaps and vertical arrangements consume space in the unified bounds. Center uses the same maximum backing scale on every screen, preserving global geometry across mixed Retina scales.

Multiple screens use the shared native transport introduced in #44. Geometry changes, mirror-to-panorama transitions and disconnection reuse that transport when possible. A failure to present a shared layer pauses/mutes the failed pool and reports an explicit reload/mirror recovery message. Panorama never silently substitutes independent playheads. A deliberate reload/application invalidation permits another attempt; ordinary repeated refresh does not retry forever. Mirrored mode retains its independent-player compatibility fallback.

No panorama-sized CPU bitmap, frame polling, custom shader or additional decoder is allocated by the application. This is not a bound on OS decoder scratch buffers, GPU/WindowServer memory or HDR resources. Existing photo/GIF admission budgets continue to apply; native video remains AVFoundation-managed.

Tests use generated rotated H.264 and synthetic targets on one physical screen. They cover every fit, negative origins, vertical gaps, mixed scale, shared player identity, mode changes, disconnect, source clearing, fail-closed panorama and explicit reload. Persistence/model tests cover native local/remote video and continued web exclusion. These checks do not certify physical monitor seams, mixed refresh-rate timing, HDR/EDR or the oldest supported macOS release.

Local validation: 50 Rust tests and Clippy, 39 Python tests, 169 Core tests, 235 AppKit cases (13 explicit skips), release build and strict codesign verification passed. Physical display/HDR and assistive-technology QA remain separate. Remote CI is blocked by #11.

An additional reverse-mode regression exercises a pool created in panorama, reused in mirrored mode and then rejected by the native readiness check. It confirms independent fallback remains available in the current mirrored mode. All 11 targeted shared-video/panorama cases passed; no production source change was needed for this case.
