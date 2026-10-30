# Prepared photo batch budget

PhotoPreparation previously retained every distinct successful result until a multi-display batch finished. The existing 128 MiB per-photo decode limit did not bound their aggregate.

The preparation batch now retains at most 256 MiB of accepted CGImage row-stride bytes (bytesPerRow × height). Arithmetic checks the remaining allowance before multiplication. Exact CGImage identity is counted once, and identical requests still share one decode/result. Each new batch starts a fresh allowance; errors are retained without their rejected bitmap. A rejected display keeps its previous renderer through the existing non-mutating error path and receives an explicit batch-budget message. Assignment persistence is unchanged.

This is a retained-result budget for one preparation batch, not a global active-photo or process memory limit. A decoder must produce its bounded result before actual stride is known; the in-flight result, codec scratch, prior installed surfaces, canceled work awaiting an uncooperative codec, AppKit/GPU copies and other batches are outside this figure. Production ImageIO decoding remains serialized with its existing per-photo checks. This change does not claim an RSS, energy or throughput improvement, and does not automatically lower photo resolution.

Small injected bitmaps exercise exact allowance, stride accounting, excess rejection, shared identity/request deduplication and renewal on a later batch. A temporary-file coordinator fixture verifies that the accepted monitor changes while the rejected monitor retains its original window. No host memory-pressure tool or user media is used.
