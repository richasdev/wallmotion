# GIF structural work budget

Every Rust public GIF probe now permits at most **1,000,000 structural loop iterations**, independently of its decoded-canvas byte budget. One unit is consumed before each main-block iteration and each data-subblock iteration, including terminators/trailer. Fixed-size headers/palettes remain bounded operations; compressed payloads are skipped without LZW decoding. The same cursor handles slices and file descriptors.

A small canvas does not constrain a long sequence of comments/extensions. This new policy can reject a structurally valid but exceptionally complex file; converting it to MP4 or simplifying the GIF is the recovery. A budget rejection can happen before validation of the remaining file. The first encountered failure wins, so a decoded-byte rejection or malformed early header can still precede work exhaustion.

`StructureBudgetExceeded` maps to C status **3**, distinct from invalid/read error (1) and decoded-byte budget (2). Swift maps 3 to `LibraryError.gifTooComplex` with its own message. All failure paths preserve the caller's output. The compatibility `wm_gif_probe` entry point also enforces this limit; C signatures and the WMGifInfo layout are unchanged. The header documents the expanded result contract.

This is a parser-control-flow limit, **not a wall-clock deadline or a CPU/RSS cap**. File metadata/pread, short-read/EINTR retry, filesystem latency and later ImageIO decoding have separate behavior. The fixed file read-ahead remains 8192 bytes. No extra full-file allocation or recursive structure is added to the production scanner.

## Verification

Five Rust tests add exact slice/file boundaries (a minimal GIF needs 4 steps), empty extension and nonempty subblock accounting, rejection before a reader touches the remaining tail, and default FFI status/output/descriptor-offset preservation. A 500,000-comment fixture exceeds the default structural budget while its image needs only 4 decoded bytes. Swift checks its Data and descriptor paths, distinct message, and rejection before a managed import directory is created. Small step limits are test-internal; callers cannot disable the app's fixed structural policy.

### Warm scanner timing sample

Existing `probe_file_bench 10000`, release Rust, same 120-frame/1820-byte fixture, alternating slice/file order within each run:

| Path | Before p50 / p95 | After p50 / p95 |
| --- | --- | --- |
| Slice | 2000 / 3333 ns | 2083 / 4625 ns |
| FD (dup + metadata + pread) | 7459 / 12750 ns | 7875 / 17583 ns |

These are single before/after runs with background app/development activity, not isolated or statistically conclusive comparisons. The new checks add work; this sample does not show a speed gain. It excludes import/copy, decoder, cold I/O, GPU, memory and energy. Raw local logs: `/tmp/wallmotion-gif-work-before.log` and `/tmp/wallmotion-gif-work-after.log`. The benefit is predictable structural rejection, not a measured throughput improvement.
