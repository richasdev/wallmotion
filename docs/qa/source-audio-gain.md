# Per-source audio gain

Issue #154, the gain portion of #45. Cancellable ramps remain #155; this change
adds no fade timers and does not complete #45 by itself.

`LibraryState.audioGains` stores optional normalized levels by library-item UUID.
Missing values mean 1.0, reset removes the override, and removing an item deletes
only its preference. Duplicate URLs/library entries retain independent levels.
The field is additive to the existing v4 format: libraries from versions 1–4
without it migrate with their original master level and assignments. Validation
rejects nonfinite/out-of-range values, foreign keys and preferences for silent
photo/GIF items. This is attenuation from 0–100%, not amplification above the
source's original level.

`AudioConfiguration` contains only owner ID, master level and the gain map. The
composed value is master × source gain; invalid numbers fail closed. A renderer
keeps its configured level for resume, but delivers zero and mute while unowned,
paused, occluded or stopped. Web policy also sends zero when disabled. Exactly one
logical display is eligible to output sound; GIF/photo surfaces have no audio
transport. Provider autoplay restrictions and asynchronous SDK behavior still
apply; these tests do not certify physical audio output or remote-provider latency.

Master, owner and source changes use `setAudioPreferences` on current renderers,
without starting media preparation, reconstructing windows or seeking players
solely to change audio. Ineligible renderers are silenced before ownership is
applied. A retained renderer whose item differs from the pending assignment cannot
regain sound. Existing visibility/pause handling may still create or discard web
views when visibility changes; the hot-update guarantee concerns unchanged policy
and media.

The coordinator keeps the current small audio configuration independently of
pending photo/GIF work. Reconciliation and newly installed renderers use it rather
than captured old library settings. Watcher and geometry reschedules merge current
audio into their state, preventing a reload from restoring a previous owner or
level. The snapshot shares only the preference dictionary, without holding another
catalog or media buffers.

UI distinguishes “Volume geral” from “Volume deste fundo”, provides 100% reset and
shows the combined output percentage. The per-source control applies to the active
video on the selected display and is keyed by item UUID. A disappearing editor can
only save that same item's draft; removal/read-only guards reject stale edits.
Slider writes are coalesced after editing or keyboard inactivity, rather than
persisting every pointer sample. The menu exposes the gain of the current connected
audio owner's video. Changing the selected display does not erase source levels.

## Evidence

Core tests cover legacy defaults, round-trip and independent levels for duplicate
URLs, master composition, zero levels, removal/reset, invalid values and foreign or
silent-source keys. Five AppKit integration tests cover:

- Real local H.264 players: correct composed levels, zero/mute on non-owner, owner
  transfer, pause/resume, old retained assignment gating, unchanged players/items/
  windows, store persistence and zero output after stop. The fixture has no audible
  track, so this verifies routing properties rather than sound-wave measurements.
- Offline YouTube/Vimeo-source WebKit documents: composed values and disabled zero
  delivered through the app bridge while retaining the same views. Existing official
  provider-script tests still verify SDK command formatting and stale-unmute guards;
  this is not a live provider certification.
- Invalid/unsupported IDs and failed saves preserve preferences; removal cleans only
  its own gain.
- A blocked photo completion cannot restore old owner/master/gain values.
- An atomic GIF replacement triggers a watcher rebuild without resurrecting old audio.

The native fixture waits for AVPlayerLooper to populate its initial item before
checking item identity. An earlier full run with the premature unwrap failed and
stalled; it was stopped and sampled. The fixed fixture passes targeted runs and the
subsequent full suite. No passing result is claimed for the interrupted run.

Local full validation passed: 50 Rust tests, Clippy with warnings denied, 35 Python
tests, 164 Swift Core tests and 200 AppKit tests (10 opt-in skips). Final slider-label
polish was checked with native dark/light captures and targeted tests; the release
app built and passed strict ad-hoc signature verification. Both control captures
were inspected for readable labels, correct percentages and no duplicate heading.
Captures use `WALLMOTION_SOURCE_AUDIO_SNAPSHOT_PATH` and optional
`WALLMOTION_SOURCE_AUDIO_LIGHT=1` in `SourceAudioGainTests` with a private store.

Commands: `sh scripts/check.sh`, `swift test -j 2 --filter SourceAudioGainTests`,
`sh scripts/build-app.sh`, `codesign --verify --strict dist/Wallmotion.app`.
GitHub CI remains blocked by billing (#11). No measured CPU/energy/RSS improvement,
physical multi-monitor audio result or completed fade behavior is claimed.
