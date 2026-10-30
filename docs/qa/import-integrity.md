# Import snapshot checks

An empty regular file is now rejected before GIF scanning or creation of a managed destination, with a useful empty-media error. Import still pins the input descriptor and copies data/xattrs with `fcopyfile`, preserving its existing quarantine handling and 0600 destination mode.

Before returning a copied item to the model, the operation checks destination length against the initial input length and re-stats the pinned input. Changed size, modification timestamp or status-change timestamp rejects the operation and removes the incomplete destination through the existing directory-relative rollback. This catches truncation, growth, short successful copy and observable metadata changes. Changing metadata during import can conservatively reject an otherwise usable copy; retry with a stable source.

These are consistency checks, not a coherent filesystem snapshot, content hash or full media-format validation. Same-size rewrites that evade the sampled metadata, malicious concurrent mutations and races after the final sample remain possible. Nonempty photo/video data can still fail during later decoding. GIFs keep their structural preflight before and after copying. Existing same-UID/ancestor/path handoff limits in managed-media.md remain applicable.

## Verification

Six tests add empty JPEG/GIF/MP4 rejection, truncating a real temporary source immediately before actual `fcopyfile`, source growth immediately after real copying, explicit timestamp change, injected short copy success, and an injected ENOSPC error after a partial write. Deterministic injection is confined to the internal copy operation; production continues to call the native copy API. Failure tests assert rollback and source preservation where the test itself did not deliberately mutate the source. ENOSPC injection does not fill the host disk.

Existing private mode, byte/quarantine preservation, symlink/FIFO containment, GIF parsing and library/model tests continue to run. No user files or OS preferences are changed by these fixtures. No throughput, memory or energy gain is claimed for the additional metadata checks.
