# Host-process power assertion audit

Run `python3 scripts/audit-power-assertions.py --pid <Wallmotion-PID>` on macOS. It only queries `/usr/bin/pmset -g assertions`; it never sets a power policy, sleeps/wakes a display, starts playback or reads a library. The installed macOS `man pmset` documents assertions and distinguishes querying from privileged setting changes.

The JSON contains only the supplied PID and counts by assertion type. Global summaries, other processes, assertion names/IDs, URLs and command paths are omitted. The query uses C/UTC for its child only and a five-second timeout. Existing collector validation checks current UID, Wallmotion command prefix and ordinary process identity before and after the query. This is not a strong security identity, and start-token resolution cannot exclude very fast same-second PID reuse.

Exit codes:

- `0`: no `PreventUserIdleDisplaySleep` observed for that host PID in this snapshot.
- `3`: one or more such assertions observed; inspect under a controlled workload.
- `2`: unavailable/changed PID, failed/timed-out query, unsupported/incomplete output or invalid invocation. No clean JSON is emitted for a failed audit.

The parser requires a complete owning-process section and recognizes the tested macOS row grammar. Unexpected owner-row layout or malformed target assertions fail closed. It accepts both kernel-section terminators observed/supported by the fixture formats. Output above 4 MiB is rejected after subprocess capture; this is not a streaming memory cap. The tool is intended for the trusted local macOS command, not adversarial input or security certification.

## Coverage and limits

Desktop player construction already sets `preventsDisplaySleepDuringVideoPlayback = false` for native local/remote players; existing renderer tests assert it. This change does not invent a WebKit setting or alter players. WebKit/helper attribution and actual screen sleep need physical runtime QA.

A local read-only snapshot on 2026-10-30 UTC of the running host PID 31520 reported no owned assertions. Its workload was uncontrolled: this does not certify video, web, pause/thermal states or absence of WebKit assertions. Absence in a snapshot does not establish zero energy use, actual display sleep, or future compliance. RSS/CPU/energy remain separate metrics. The broader matrix in #91 and whole-app protocol in #8 remain open until measured.

Unit fixtures cover exact PID matching (123 vs 12/1234), duplicate types, other-process privacy, malformed/unsupported/truncated output, large input, start-identity change, child timeout configuration and distinct clean/present/error exit statuses. They do not modify OS power settings or prevent display sleep.

## Controlled native matrix

The [isolated runtime matrix](runtime-policy-matrix.md) now records native active,
manual-pause, synthetic occlusion and injected thermal-pause states, 120 seconds
each. All eight host boundary snapshots observed no display-sleep assertion; each
phase verified native sleep prevention disabled. This adds a measured native
matrix to the earlier uncontrolled snapshot. It does not certify WebKit helpers,
actual screen sleep or future assertion state. Raw sample data and limits are
linked from that report.
