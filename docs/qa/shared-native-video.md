# Shared native video transport (#44)

Mirrored native video now uses one AVPlayer (and one local AVPlayerLooper or remote recovery adapter) with one AVPlayerLayer per display. Layers keep AVFoundation's color/rendering path. The application does not pull pixel buffers or composite frames during normal playback. This proves shared application transport, not a count of hardware decoder sessions or zero-copy behavior inside the OS.

Any visible playing subscriber keeps transport alive. Only one visible playing audio owner may contribute its normalized global × source gain; duplicate owners fail closed to mute. Covering the owner mutes without pausing another visible display. Manual fades stay in the renderer; system pauses, source failures and loss of ownership cut immediately. Stopping one renderer unsubscribes it without clearing the surviving player's item. Delayed renderer KVO cannot reinterpret the shared player as a private player after stop.

Layer readiness is checked only while multiple visible layers are requested and transport actually plays. A cancellable two-second deadline falls back once to independent native players if a layer cannot display frames. It is canceled when paused, stopped or ready. A rejected source is not retried indefinitely in the same coordinator lifetime. This is a readiness fallback, not a detector for HDR/color errors or every macOS compatibility issue.

## Local verification

`SharedVideoTests` covers shared identity, hot volume, owner occlusion and transfer, manual pause/resume, disconnect, stale callbacks after unsubscribe, bounded readiness fallback, cancellation while paused, duplicate-owner muting and HLS preference propagation through the shared adapter. The remote-adapter test injects a local player item; it performs no network request and does not certify live HLS.

Run the native presentation check explicitly:

```sh
WALLMOTION_SHARED_VIDEO_RENDER_QA=1 swift test -j 2 --filter SharedVideoRenderingTests.testNativeSharedLayersDisplayTheSamePausedFrame
```

It opens two small QA windows with generated H.264, waits for both native layers to become ready, pauses their common player and compares a pixel from each displayed buffer. On the development host both layers provided matching, nonblack samples. This checks SDR content through actual native layers; it does not certify physical multi-monitor refresh, HDR/EDR or every supported OS release.

## Opt-in resource study

```sh
WALLMOTION_SHARED_VIDEO_BENCHMARK=/tmp/new-shared-video-report.json swift test -j 2 --filter SharedVideoRenderingTests.testOptInNativeTransportResourceComparison
```

The test uses generated 1280×720 H.264 at 30 fps and two 160×90 native layers. It runs two independent transports, one shared transport, then two independent transports, each with five seconds of warmup and thirty seconds measured. All are silent and set preventsDisplaySleepDuringVideoPlayback=false. Existing reports are never overwritten. Temporary generated media and QA windows are cleaned up.

Public proc_pid_rusage RUSAGE_INFO_V6 reads only the current XCTest process. CPU time, cycles, instructions and kernel-accounted task CPU energy are endpoint deltas. CPU time is converted from Mach ticks with the reported mach_timebase_info numerator/denominator before calculating a percent of one CPU. The raw tick delta is retained for auditing. Physical footprint is reported at the two endpoints, not as a peak. Unsupported counter access fails the opt-in run. A zero energy delta alone is not evidence that energy accounting is available or that consumption is zero.

The time conversion follows [XNU’s own counter comparison](https://github.com/apple-oss-distributions/xnu/blob/main/tests/recount/recount_perf_tests.c). Apple describes the resource accounting in [XNU Recount](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md). Task CPU energy excludes total GPU, display, helper-process, system and battery energy. The fixed A–B–A order, single run, XCTest baseline and retained framework caches limit causal conclusions; do not extrapolate a battery-life percentage or claim one hardware decoder from player identity alone.

### Development-host sample

Compiled source `d6c765303486cfe15acd14f37c215dae04c421a5`, macOS 27.0.1 arm64, native-layer parity passed. [Recorded scalar evidence](evidence/shared-native-video-20261101.json):

| Transport | CPU, one-core % | Cycles | Task CPU energy | Footprint before → after |
| --- | ---: | ---: | ---: | ---: |
| Two independent, first | 4.3169 | 2,251,140,102 | 309,144,586 nJ | 38,044,560 → 27,345,784 B |
| One shared | 2.9498 | 1,521,628,287 | 172,489,075 nJ | 26,706,808 → 26,575,736 B |
| Two independent, repeat | 4.3437 | 2,267,798,324 | 307,324,863 nJ | 26,854,264 → 27,083,640 B |

This run observed lower task CPU time, cycles and CPU-energy accounting for the shared path. Footprint endpoints do not establish a memory improvement. The small layers, synthetic content, fixed order and one host prevent a general performance or battery claim. HLS network variation, HDR and physical multiple displays are outside this sample.

Final local checks: 50 Rust tests and Clippy, 39 Python tests, 168 Core tests and 232 AppKit cases (13 explicit skips) passed. Both opt-in native presentation/resource cases passed separately. Release build and strict codesign verification passed. GitHub Actions remains blocked by account billing (#11); these are local results.
