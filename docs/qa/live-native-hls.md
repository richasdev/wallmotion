# Real native HLS observations (refs #101)

This opt-in test exercises the production WallpaperRenderer, RemoteVideoPlayback and AVPlayerLayer with an explicit HTTPS stream. It does not use the synthetic server or add a production frame-copy loop. The native desktop QA window may briefly appear; no library, user media, permissions or display/power preferences are changed. Visibility is injected as true to keep the test workload playing.

```sh
WALLMOTION_HLS_QA_URL='https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8' \
WALLMOTION_HLS_QA_OUTPUT=/tmp/new-native-hls.json \
swift test -j 2 --filter LiveHLSMatrixTests
```

The JSON path must not exist. Without both environment variables the case skips before networking or creating a window. It waits up to thirty seconds for native readiness, then observes automatic → 720p → 4K → automatic for ten seconds each. Every step must retain the same player item and progress in a muted transport with display-sleep prevention off. It samples one displayed buffer per step only for dimensions/pixel-format/color metadata, and exports allowlisted access-log scalars without URI, server address or raw errors. A paused final preference update must not resume playback; stop must clear the item and layer.

## Public developer examples

Apple lists the [Bip Bop and advanced Dolby Vision/HDR examples](https://developer.apple.com/streaming/examples/). The second URL used here was `https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8`. Both master manifests were fetched with bounded reads; their SHA-256 values are included in the evidence. A manifest advertising HDR does not prove that an HDR rendition was selected.

Source `972bb8d91addc9d7aa82b40bc2d7471a55b7c3df`, macOS 27.0.1 arm64, passed both native cases (41.324s / 41.279s). Actual observations:

| Stream | Preference sequence | Displayed buffer sequence | Transfer metadata |
| --- | --- | --- | --- |
| Bip Bop | automatic / 720p / 4K / automatic | 1920×1080 at all four boundaries | ITU_R_709_2 at all boundaries |
| Advanced | automatic / 720p / 4K / automatic | 3840×2160 / 1280×720 / 1280×720 / 1280×720 | SMPTE_ST_2084_PQ at all boundaries |

All eight sampled boundaries had a ready native layer, advancing playhead, mute enabled, volume zero and no player display-sleep prevention. Access logs recorded changes in indicated bitrate even when the displayed buffer stayed at its earlier dimensions. Observed bitrate is transfer throughput; it is not decoded resolution. No hard-cap or immediate-switch assertion is made. Ten seconds can retain already buffered media; raising a preference need not immediately upgrade what is displayed.

The single attached display reported 1512×982 points at 2×. Potential EDR headroom was 16; current EDR headroom at report time was approximately 1.2 after Bip Bop and 16 after the advanced stream. These are public capability/runtime scalars, not a luminance/color calibration. No screen rotation or display setting was changed.

Evidence: [Bip Bop scalars](evidence/live-hls-bipbop-20261101.json), [advanced scalars](evidence/live-hls-advanced-20261101.json).

## Remaining acceptance work

Issue #101 stays open. The real selected buffers here were SDR throughout the first case and PQ throughout the second; neither case proves a transition between SDR and HDR within a stream. Portrait adaptive media on a physically vertical monitor, visual color/flicker assessment, unavailable-compatible variants and live DRM failure remain unverified. The existing synthetic portrait observation is not a substitute for those cases. No CPU, GPU, energy or battery claim is derived from these playback observations. See [synthetic probe limits](hls-probe.md) and [preference semantics](hls-quality.md).

Local offline check: 50 Rust tests and Clippy, 39 Python tests, 168 Core tests and 233 AppKit cases (14 explicit skips) passed. Both network cases passed separately. No production source changed; remote CI remains blocked by #11.
