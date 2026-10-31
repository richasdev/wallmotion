# Shared native GIF runtime

Runtime portion of #147 and #14, using the descriptor decoder from PR #149.
These issues remain open for the asynchronous assignment-admission follow-up #150.

## Behavior

The production `scheduleRebuild` path prepares GIF frames on the serial
`GIFDecodeWorker` actor using the Rust decoder. Immutable frames are keyed by
POSIX device/inode/size plus nanosecond mtime **and ctime**. Multiple displays or
hard-linked URLs reuse one `PreparedGIF`, one shared playback clock and the same
current `NSImage`. A separate point-size override keeps native center geometry
correct for each display's backing scale without mutating the shared image.
Photos keep their existing ImageIO preparation path. The direct synchronous
renderer/rebuild entry remains an internal fixture path; production callers use
`scheduleRebuild`.

A weak cache admits at most 512 MiB of live unique GIF frame payload. It also
limits a new decode's existing pixel-working budget to the remaining global
allowance, up to the decoder's 384 MiB working ceiling. The per-file output cap
remains 256 MiB. This is **not a process-RSS cap**: AppKit/GPU raster caches,
allocator overhead, codec auxiliary buffers and unrelated app resources are not
included. Replacement may fail until old surfaces or external image consumers
release their allocations; old valid pixels remain installed on failure.

Every CGImage provider may retain the immutable accounting object, so frames
still held by CoreGraphics count even after the renderer or Swift image factory
is gone. Providers own native references independently. No mutable decoder or
encoded-file copy remains in the playback clock.

Logical delays preserve positive centiseconds. Zero delay uses the explicit
product policy of 100 ms. Presentation wakes no faster than 60 Hz, selecting the
current logical frame and skipping overdue frames. Background playback loops
continuously, including finite-loop files; the original repeat metadata remains
available on the immutable animation. A one-frame GIF needs no tick task. With
no active subscribers the timer is cancelled and phase is frozen. Manual pause,
occlusion, screen lock/sleep, power/thermal policy and memory lifecycle continue
through the existing renderer policy. GIF audio remains silent.

Each subscribed source URL has inode and parent-directory notifications. The
parent notification permits recovery after multiple atomic replacements, even
when a corrupt intermediate file leaves the old renderer installed. Unrelated
directory writes are filtered by identity. Subscription rechecks identity after
arming watchers to detect a replacement before installation. Last unsubscribe
cancels that URL's sources; descriptor close occurs in dispatch cancellation.
This is metadata-based invalidation, not an atomic or cryptographic snapshot
against hostile filesystem writers. Watcher setup can fail; a later explicit
refresh still checks identity.

Coordinator generations cover both GIF preparation and the following photo
batch. Stale results cannot install when a newer assignment is waiting, after
clear, after deferral under memory pressure or after stop. A cancelled native
decode retains the serial worker slot until it actually returns, then discards
its result.

## Evidence and limits

`SharedGIFTests` uses private temporary files and synthetic display targets:

- Native worker execution off the main thread; hard-link deduplication; provider
  lifetime accounting and rejection while old payload is still retained.
- Cancelled uncooperative decoding, replacement invalidation, pending-request
  reuse with latest callback, and suppression of obsolete batches.
- Shared NSImage frames from a real timer; deterministic phase skipping, one
  covered subscriber, all paused, resume, one-frame transport and clock teardown.
- Two native desktop windows with the same image, distinct center geometry at
  backing scales 1 and 2, one remaining charge after clearing a display, and zero
  retained native payload after stop and release of the test's own view references.
- Corrupt headers and structurally admitted invalid compressed pixels preserve
  the old renderer; repaired atomic replacements install new frames.
- Watcher reloads respecting memory-warning deferral until recovery.
- Replacement before watcher installation, unrelated directory writes, and an
  old photo completing while the new GIF decoder remains blocked.

Core tests cover timeline boundaries/looping, zero-delay normalization, nonfinite
inputs, unique-source budget release, conflicting estimates, legacy identity
namespaces and overflow. Existing CoreGraphics/AppKit paint tests still cover
native frame colors and provider ownership. Physical monitors, HDR, comparative
CPU/RSS/energy measurements and long-running visual QA remain external evidence
items (#8/#43); this change claims no measured performance gain.

The first structural assignment validation still performs a bounded synchronous
preflight before persisting selection. A 128-entry identity memo avoids repeated
scans during refresh. Moving that admission transaction off the main actor is
still required by #147 and is the next implementation step; native pixel decode
and playback sharing are already exercised here. A structural preflight does not
guarantee rejection of every corrupt compressed stream.

Local results: 50 Rust tests, Clippy with warnings denied, 35 Python tests,
158 Swift Core tests and 186 AppKit tests (10 opt-in skips), all passed. The
release app built and passed strict ad-hoc signature verification.

Validation: `sh scripts/check.sh`, targeted `swift test -j 2 --filter SharedGIFTests`,
`sh scripts/build-app.sh`, and `codesign --verify --strict dist/Wallmotion.app`.
Remote CI is blocked by GitHub billing (#11); local results do not imply remote CI.
