# Asynchronous GIF assignment admission

Completes the structural-admission follow-up #150 to runtime PR #151, contributing
to #147 and #14. The product remains Wallmotion.

`GIFAdmissionWorker` owns structural file inspection and a bounded 128-entry
identity memo. Its actor is separate from MainActor and the native decode worker.
The UI creates a small request of connected display IDs, URLs and the aggregate
limit; it never passes a whole library snapshot through the file-I/O suspension.
No task-priority assumption is used to move work off MainActor. The native worker
awaits admission **before** its serial, non-suspending allocation/decode section;
it checks live resources again after that await.

Library selections and mirror-mode changes validate before saving. Pending
intents have tokens scoped to each independent display or shared/mode operation.
A newer choice cancels the previous choice for that target. Independent displays
can validate concurrently. Before committing, state revision is checked: settings,
renames, imports and other display changes cause the intent to be rebuilt and
validated against current state, preserving those changes and the combined quota.
Invalid, over-budget, removed, disconnected or cancelled choices cannot persist a
stale snapshot or present a stale validation error. Clear, stop and load cancel
pending work; removal cancels pending assignment transactions before deleting media.
Photo/video-only layout changes keep their immediate path without parsing GIFs.

Runtime restoration also goes through asynchronous batch admission before native
preparation. Its metadata is handed to reconciliation, which never falls back to
structural inspection on the production path. Existing windows remain until a
replacement succeeds. Generation checks still cover GIF admission/preparation and
the following photo batch. Mode changes clear obsolete whole-state errors; reused
remote renderers republish their actual state. A native small progress indicator
says “Verificando fundo…” while selection validation is pending and leaves other
controls usable. Native preparation failures now have actionable Portuguese text
instead of reflected internal error names.

The main actor still resolves managed paths, performs point-in-time identity
checks and saves the final library state. These filesystem metadata/save operations
are not claimed to have zero latency. A source identity is rechecked after the
background scan and again before renderer installation. Observations are not an
atomic or cryptographic snapshot against hostile writers. Cancellation is
cooperative at scan boundaries; a synchronous scan/decode holds its actor slot
until it actually returns. No wall-clock I/O deadline is claimed.

Admission validates container structure, estimated frame payload and structural
work. It does not validate every compressed LZW stream: a structurally admitted
pixel-decode failure may occur after selection persistence, with the old renderer
preserved and a playback error shown. No claim is made that preflight alone
rejects every corruption. The global ceiling remains a bound on described GIF
payload/working resources, not process RSS. Physical display/HDR tests and measured
comparative CPU/RSS/energy remain #8/#43; this change reports no measured speedup.

## Evidence

Nine new `AsyncGIFAdmissionTests` use private temporary stores and synthetic display
targets. They cover a blocked worker while MainActor handles volume; A→B→C with a
stale error and skipped queued B; concurrent independent assignments plus rename;
budget/corruption rejection preserving store bytes and installed windows; clear
and stop; load, removal and disconnect; two individually valid choices exceeding
the combined quota; source replacement without memoizing its old identity; startup
admission respecting a later pause; and mode changes clearing obsolete errors.
Thread assertions are inside the injected real structural scan, and success paths
still use native GIF/ImageIO preparation. Existing runtime/provider/clock tests remain.

An offscreen native SwiftUI capture of the pending state was generated with
`WALLMOTION_ADMISSION_SNAPSHOT_PATH` and inspected: the readable indicator appears
above playback status, current selection remains marked, and controls are visible.
This is a synthetic dark-mode fixture, not a physical monitor or VoiceOver audit.

Local validation passed: 50 Rust tests, Clippy with warnings denied, 35 Python
tests, 159 Swift Core tests and 195 AppKit tests (10 opt-in skips). The release app
built and passed strict ad-hoc signature verification.

Run `sh scripts/check.sh`, `sh scripts/build-app.sh`, and
`codesign --verify --strict dist/Wallmotion.app`. GitHub CI remains blocked by billing
(#11); local evidence must not be described as a remote CI pass.
