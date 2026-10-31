# Manual audio transitions

Issue #155 completes the manual-transition part of #45 after per-source gain
(#154 / PR #156). The configured output remains master × source attenuation.
Only a manual pause/resume gets an envelope. Automatic policy, ownership loss,
zero gain, occlusion and stop take precedence and cancel it immediately.

## Native playback

`AudioRamp` is a bounded smoothstep envelope with a 200 ms duration. A manual
pause retains transport only while fading to zero, then mutes and pauses it.
A manual resume starts at zero and waits for AVPlayer's `.playing` state before
starting its clock. Buffering holds at zero with no periodic tick; a subsequent
playing transition starts a fresh envelope. Reversals use the current envelope
value; reversing into buffering also resets to zero. `.playing` is an AVPlayer
transport observation, not proof of audible samples reaching hardware.

There is at most one 16 ms sleep task per native renderer while an envelope is
advancing. A generation invalidates old tasks; KVO wakes a waiting resume without
polling. Clock and readiness injection are internal deterministic test seams.
Transport play/pause calls are conditional and synchronous remote callbacks are
coalesced to avoid reentrant state mutation.

The model distinguishes manual UI actions from its combined sleep/session/lock,
thermal, memory and power policy. A manual toggle while an automatic pause is
active cannot resume playback. System resume keeps its existing immediate policy.
Any rebuild or changed audio configuration can cancel an in-flight manual fade.

## Official web players

A manual transition first obtains a snapshot of SDK-reported volume and mute
state from an already ready/playing document. The wrapper then requests an
intermediate step at approximately 100 ms and the final target at 200 ms, using
the same smoothstep curve. A recreated resume document starts muted. Each request
has one UUID, one pending reply and a 150 ms reply deadline. The Swift bridge checks
the current document, main frame, token, finite bounded level and expected mute
state. No Swift continuation waits for an unresolved provider promise.

YouTube setters return no acknowledgement; the wrapper checks `getVolume()` and
`isMuted()`, with at most seven getter attempts separated by 16 ms and integer
percent quantization. Vimeo uses setter promises and `getVolume()` / `getMuted()`;
its gain requests and snapshots share a serialized chain. Version checks prevent
obsolete continuations from unmuting, and a reversed snapshot waits behind a
setter already in flight so it cannot later overwrite a confirmed target.
Official contracts: [YouTube IFrame API](https://developers.google.com/youtube/iframe_api_reference)
and [Vimeo Player SDK](https://github.com/vimeo/player.js).

Replies certify only the state reported by the SDK, not physical audio output.
Provider delay can extend the overall transition beyond 200 ms. The web envelope
has fewer steps than native playback; this is not a claim of sample-accurate
fading, remote latency or removal of audible clicks. If commands fail, getters
report a different state, or a reply deadline expires, the app suspends playback
through native WebKit APIs, discards the document and reports a recoverable error.
It does not automatically restart that failed renderer. Pausing successfully also
discards the document, preserving the existing low-resource paused lifecycle.

Hard policy changes, occlusion, system pause and stop cancel timers and discard an
active web transition immediately. A delayed SDK unmute belongs to the discarded
document. Unchanged audio policy during a manual fade does not overwrite its
levels. Ownership and zero-volume changes without a fade keep the existing hot
policy path.

## Verification

- Three Core tests verify endpoints, midpoint, monotonicity, bounds, invalid input
  and reversal continuity.
- Eight native integration tests exercise actual local H.264 AVPlayers, real timer
  completion, rapid reversal, injected buffering/stalls, reverse while buffering,
  zero/muted sources, ownership loss, occlusion and stop. A private-store model
  test routes real manual toggles and synthetic in-process workspace sleep/wake
  notifications through production policy without sleeping or locking the Mac.
- Seven web tests cover offline WKWebView pause/resume, intermediate/final values,
  rapid reversal retaining the document, invalid/missing/stale/mismatched replies,
  immediate ownership/system/volume/stop cuts, and parent-renderer visibility while
  logically paused. JavaScriptCore executes the shipped official-provider wrappers
  against mocked SDKs to verify quantization, bounded retries, Vimeo serialization,
  ignored setters and stale unmute cancellation.

Native fixtures contain no audible track. Offline web fixtures do not certify
live YouTube or Vimeo (#42), physical lock/sleep latency, multi-monitor output,
hardware click reduction or energy/CPU/RSS changes (#8). No user media, login item,
power setting or real screen lock is changed by these tests.

Local full validation passed: 50 Rust tests, Clippy with warnings denied, 35
Python tests, 167 Swift Core tests and 215 AppKit tests (10 opt-in skips). The
release app built and passed strict ad-hoc signature verification. Commands:
`sh scripts/check.sh`, `sh scripts/build-app.sh`, and
`codesign --verify --strict dist/Wallmotion.app`. GitHub Actions remains blocked by account billing (#11).
