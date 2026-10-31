# Isolated native policy matrix (#8 / #91)

`python3 scripts/qa-runtime-matrix.py --run --output /tmp/new-matrix.json` builds
and launches an instrumented, ad-hoc QA app from a trusted committed source SHA.
The default is four 120-second phases at 1 Hz, each after 10 seconds of warm-up.
A shorter `--duration 3 --warmup 1` is only a smoke check. The output and associated
`.build.log` must be new paths. Working edits are excluded from the archive.

Only the private archive is modified: the default library root, model factory and
launch hook are replaced after exactly-one-match checks. A fixture outside all
production SwiftPM targets is injected there, alongside unique bundle metadata.
It creates a silent H.264 video (1280×720, 30 fps, four-second loop), imports through
the production model, and uses a synthetic offscreen target. Production renderer
and policy code run with injected visibility and thermal-pressure inputs. This is
not a measurement of the user's existing library or an unmodified desktop session.

Phase commands use a filesystem event source, not a persistent polling timer in
the measured process. The driver waits for native readiness/progress or pause,
checks the silent fixture and `preventsDisplaySleepDuringVideoPlayback == false`,
then uses the existing collector and power-audit tools. It checks native state
again at the end. These are boundary checks, not a continuous frame-progress audit.
Power queries are likewise boundary snapshots; no actual lock or sleep is triggered.

The driver validates the unique bundle/path and private library owner. Cleanup
requests native quit, then uses SIGTERM only after revalidating owned QA processes.
An unconfirmed exit preserves the archive instead of deleting a live app. No sudo,
HOME override, user media, production-library access, login registration, OS
permission changes or power-setting changes are used. Temporary QA UI may appear.
This is a workflow for trusted source, not an OS sandbox or atomic process capability.

## Observed run

Source `baf6c0dd4dac9250b6aaf04d0384d0972afe67f0`, macOS 27.0.1 arm64,
2026-11-01 JST. All four phases completed, each with 121 samples including the
initial zero-interval sample. Observed durations were 120.0094, 120.0180, 120.0163
and 120.0086 seconds. No unrelated benchmark/compiler was intentionally launched
after sampling began; normal OS activity remains an uncontrolled influence.

| State | Weighted host CPU | Interval CPU p95 | Mean RSS MiB | RSS p95 MiB | Highest sampled RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| `active` | 2.8164% | 4.0174% | 96.93 | 127.67 | 138.45 |
| `manual_pause` | 0.0083% | 0.0000% | 58.35 | 70.30 | 101.75 |
| `occluded` | 0.0250% | 0.0000% | 39.77 | 59.70 | 64.33 |
| `thermal_pause` | 0.0000% | 0.0000% | 30.38 | 48.94 | 49.17 |

The validated QA host owned zero `PreventUserIdleDisplaySleep` assertions in all
eight before/after snapshots. Each state also reported a ready native item and
screen-sleep prevention disabled. Paused/occluded/thermal states had zero native
rate; the active state's item time advanced during the boundary readiness checks.
The temporary QA processes/source/library were cleaned after the run.

Auditable [summary and snapshots](evidence/native-policy-matrix-20261101.json)
and [484 samples](evidence/native-policy-matrix-20261101.csv) are committed without
process command paths or other processes' assertion records. The local full raw
report is `/tmp/wallmotion-policy-matrix-120s-1.json`; its checksum is in the summary.
Four Python tests cover exact-match injection, bounded durations, fail-closed native
state observations and mandatory opt-in; all 39 Python tests passed. The native
fixture compiled and passed both the smoke run and full matrix in its archived app.

## Interpretation and limits

These are host-process observations, not energy/battery measurements. CPU comes
from cumulative `ps time` deltas and has centisecond counter quantization here.
Zero deltas or p95 values do not prove zero work. RSS is resident memory at sampled
instants, not physical footprint, GPU memory or a true peak. The fixed phase order
and one run do not establish that pausing caused the declining RSS or prove a
statistically significant performance improvement.

WebKit helpers, GPU, WindowServer composition, physical visibility, actual screen
lock/sleep and HDR are outside this run. Native `AVPlayer` configuration and the
host-PID audit are covered; WebKit provider/helper compliance is not certified.
The tools never read assertion names or publish other processes' records.
CI remains blocked by GitHub billing (#11); these are actual local results.
