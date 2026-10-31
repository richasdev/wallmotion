# Interval CPU sampling

`collect-performance.py` schema 2 preserves `cpu_percent` as the existing BSD ps estimate and adds an explicit `ps_cpu_percent` alias. The installed macOS `man ps` describes that estimate as a decaying average over up to a minute; it is not a fresh percentage for the collector's interval.

New fields:

| Field | Meaning |
| --- | --- |
| cpu_time_seconds | Accumulated user + system CPU time from ps time |
| cpu_time_ns | Integer representation of the parsed counter, JSON only |
| cpu_time_quantum_ns | Displayed counter resolution, not nanosecond measurement precision |
| sample_interval_seconds | Actual monotonic query-completion delta |
| cpu_delta_seconds | Difference of cumulative CPU counters |
| cpu_interval_percent | CPU delta / monotonic delta × 100 |

The first sample has null interval/delta/percentage (empty CSV cells). Values are not capped at 100 because multicore process work can exceed one core's equivalent capacity. Integer parsing supports minutes, hours, days and fractional seconds without subtracting rounded floats. Both the original CSV column order and legacy estimate are preserved; new columns are appended. JSON adds a time-weighted CPU mean, nearest-rank p95 of interval averages and highest sampled RSS, not a true memory peak.

On this Mac, ps time displays centiseconds. A 10 ms tick is a 10-percentage-point step at 0.1 s, or one point at 1 s. Query launch/completion jitter adds uncertainty; the displayed quantum is **not an overall error bound**. Zero deltas do not prove zero work, and interval averages do not show instantaneous peaks. Only the main supplied process is sampled: no WebKit subprocesses, GPU, WindowServer attribution, energy, or physical-footprint claim.

The collector fixes only its ps child's locale/timezone to C/UTC and gives the query a five-second timeout. A query may overrun the requested duration. It anchors cadence to the original start and skips missed slots rather than running recovery bursts. UTC/C-locale process start token, UID, command, elapsed time and nondecreasing counters guard against ordinary PID reuse; changed samples are not appended and prior results survive. This is not a security identity and a very fast same-second reuse can evade the start token.

## Controlled fixture

A safe Rust standard-library fixture allocates/touches 16 MiB, runs one busy thread for three seconds, then sleeps five seconds and exits. It does not reserve a particular core, launch a GUI or access any app library. Run it only as an explicit development measurement:

```sh
rustc -O Tests/Fixtures/cpu-sampler.rs -o /tmp/WallmotionSamplerFixture
/tmp/WallmotionSamplerFixture &
fixture_pid=$!
python3 scripts/collect-performance.py --pid "$fixture_pid" --interval .25 --duration 6 --format json --output /tmp/wallmotion-fixture-metrics.json
wait "$fixture_pid"
```

One local run completed 25 samples over 6.0259 observed seconds: busy-window mean 99.69%, measured idle-window counter-delta mean 0.0%, time-weighted mean 50.12%, interval p95 104.04%, sampled RSS maximum 18,595,840 bytes. The over-100 p95 for a single busy thread illustrates timestamp/quantization uncertainty; it is not evidence of extra threads. These are fixture observations, **not Wallmotion app performance or energy results**. The first interval was null. Raw local output remains in `/tmp/wallmotion-native-cpu-metrics.json`.

Unit tests cover formats/resolution, first-sample nulls, multicore percentages, PID/counter changes, partial results, cadence after slow queries, weighted summaries, CSV compatibility and bounded C/UTC ps calls. The current user's running app and its data are not used by these tests. Remaining whole-app workload/energy protocol belongs to #8.

## App workload measurements

The [native policy matrix](runtime-policy-matrix.md) records four 120-second states
in an instrumented isolated app using production policy/renderers and generated
H.264. Its CSV preserves interval CPU and sampled RSS; the report separates those
observations from energy, GPU and physical desktop certification.
