# URL entry presentation

The URL sheet is a dedicated native SwiftUI component. It shows an explicit source picker, focuses the URL field on appearance/source changes, uses a concrete window background in both appearances, wraps inline errors and preserves Return/Escape actions. Adding saves to the library; it does not apply playback.

Feedback uses the existing `MediaURL.validate` / `WebEmbed.parse` contracts. No URL resolution, provider request, thumbnail load or clipboard read occurs here. A valid syntax hint does not establish availability, video format, embedding permission or autoplay success. Direct URLs still require HTTPS without credentials; provider mode still accepts only the supported individual-video contracts. A YouTube URL in direct mode offers a source-selection hint without silently changing modes. The feedback never echoes a private URL query/hash. The field itself necessarily displays what the user entered.

Interactive entry is capped at 4096 UTF-8 bytes before URL parsing. This UI limit does not change persisted-library loading or the core direct-URL contract. Add is disabled for blank/invalid entries and when the model cannot edit or is importing; the submit handler rechecks the same conditions. Save failures remain inline and clear after editing or switching source. Reopening starts a fresh draft and does not retain a discarded secret-bearing URL.

## Verification

Unit checks cover provider-mode mismatch, YouTube timestamps, Vimeo, HLS, credentials, oversized input and private-query omission from feedback. Optional offscreen snapshots use `WALLMOTION_URL_SNAPSHOT_DIR` with the app XCTest suite and export dark valid-YouTube and light wrong-mode examples. These inspect component composition, not actual on-screen keyboard focus, VoiceOver speech or provider playback. Physical keyboard/VoiceOver QA remains necessary.
