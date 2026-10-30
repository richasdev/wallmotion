# Synthetic HLS observation (refs #101)

Run explicitly on macOS with Xcode Swift and FFmpeg/libx264:

```sh
python3 scripts/qa-hls.py --run --output /tmp/wallmotion-hls-observation-new.json
```

The output must not already exist. Without `--run`, the script exits 2 before compiling, generating media, opening a server or playing anything. It generates four eight-second H.264/8-bit synthetic variants, compiles a standalone Swift helper and observes four cases for five seconds each (automatic/1280×720, landscape/portrait). `--duration` accepts 1...7 seconds per case. Only an ephemeral 127.0.0.1 server serves exact generated assets; there are no redirects, directory listings, external media, app launches or windows. A private temporary directory is removed on exit. The immutable fixture payload has a 32 MiB allowance; a single request handler and three-second socket deadline bound serving concurrency. Output JSON is create-only, mode 0600.

The helper uses a muted AVPlayer with display-sleep prevention disabled and AVPlayerItemVideoOutput to consume frames offscreen. Each sample keeps only scalar presentation dimensions, pixel-buffer dimensions, playhead and waiting status. Access-log export retains bitrate/byte numbers, never URLs or raw error descriptions. Output includes the OS/architecture and fixed variant IDs; server request counts distinguish the generated variants. `observed` requires advancing playback plus a consumed frame; otherwise the parent reports `incomplete` and exits 2. A short run can be inconclusive.

## What the numbers mean

- `preferredMaximumResolution` is an HLS preference; zero selects no preferred limit. It is not asserted as a universal hard cap. [Apple](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredmaximumresolution).
- `presentationSize` describes the visual presentation extent, potentially zero before readiness. Pixel-buffer dimensions are recorded separately and are not assumed equivalent for arbitrary content. [Apple](https://developer.apple.com/documentation/avfoundation/avplayeritem/presentationsize).
- `observedBitrate` describes download throughput, not pixel resolution. `indicatedBitrate` and request counts add context; they do not independently certify decoded dimensions. [Apple](https://developer.apple.com/documentation/avfoundation/avplayeritemaccesslogevent/observedbitrate).
- Fixtures use FFmpeg's VOD HLS muxer with aligned keyframes and independent segments. [FFmpeg](https://ffmpeg.org/ffmpeg-formats.html#hls-2).

## Development observation

On macOS 27.0.1 arm64, five-second synthetic runs produced these consumed pixel-buffer sizes (initial zero/absent frames excluded):

| Layout | Preference | Observed frames |
| --- | --- | --- |
| Landscape | Automatic | 640×360, then 1920×1080 |
| Landscape | 1280×720 | 640×360 |
| Portrait | Automatic | 360×640, then 720×1280 |
| Portrait | 1280×720 | 360×640 |

All four playheads advanced beyond 4.7 seconds. An earlier metadata-only helper obtained presentation sizes but never advanced its playhead; it correctly reported incomplete and was replaced with frame consumption. These observations support this fixture only, not a general promise about portrait selection, a hard resolution cap or production AVPlayerLayer behavior. The standalone probe does not exercise Wallmotion's preference propagation, covered separately by native regression tests.

Issue #101 remains open for real adaptive streams, unavailable-compatible variants, rotated physical displays, HDR/SDR transitions, DRM/error behavior and visual QA. No CPU/RSS/GPU/energy improvement is inferred. Test fixtures do not change the user's wallpaper, library, audio or power settings.
