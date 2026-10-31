# Positional GIF file admission

Issue #146, continuing #14 after the immutable bridge (#145 / PR #148).

`GIFAnimation(url:limits:)` opens a local no-follow, nonblocking, close-on-exec file
through the shared GIFPreflight helper. Non-local hosts, remote URLs and malformed
empty/NUL paths are rejected before POSIX open. On this host Foundation exposes an
empty path for a URL containing an embedded NUL; a prefix-file read was not reproduced.
Rust duplicates the descriptor using BorrowedFd::try_clone_to_owned, then rejects
anything except a regular file. The caller's descriptor stays open and its seek offset
is preserved on success and failure.

Admission captures device/inode/length plus nanosecond mtime and ctime. The encoded
length ceiling is checked before content reads; allocation-free structural preflight
checks the decoded estimate and structural-work limit. Frame count is checked before
creating the codec. Identity is verified after that scan and after decoding.

The codec receives a positioned reader bounded to the initial length. It never follows
appended bytes past that boundary and never mmaps mutable pages or retains a full
encoded-file Vec. Standard codec read-ahead is small; decoded frames, ancillary metadata
and pixel working budgets remain bounded by the existing decoder contracts. Short
reads and EINTR are handled. Truncation, observed metadata changes and codec errors
return without publishing a handle. Returned frames remain valid after file close or
unlink. An added C entry point uses the existing statuses plus 9 for an observed source
change. Out remains unchanged on failure.

These metadata observations are not an atomic or cryptographically coherent snapshot
against hostile writers. The structural-work count applies to the admission scan;
codec input length, frame count, output pixel payload and ancillary buffers are bounded
separately. No wall-clock or codec CPU-time bound is claimed. A concurrently changed
stream may be rejected by the codec before the final identity comparison. External
identity/cache invalidation and cancellation policy remain part of #147. Existing
per-view/global runtime GIF budgets and renderer are unchanged here.

## Validation

Rust fixtures cover valid decode followed by unlink, output/offset preservation,
metadata-only encoded rejection on a write-only descriptor, pipes/sockets/directories/
devices, deterministic mtime change, truncate/grow during stream, partial reads, EINTR,
initial-length EOF and truncation mid-header. A sparse 64 MiB file with an early GIF
trailer verifies bounded codec read-ahead rather than reading/copying the entire tail.
These are private temporary fixtures and do not alter user media.

Swift tests cover URL preparation after source removal, symlink/FIFO/directory and
remote-host rejection, encoded/frame admission and malformed path rejection. All
existing in-memory bridge and AppKit painting tests remain. Run `sh scripts/check.sh`
and `sh scripts/build-app.sh`; physical multi-monitor playback remains #147/#14.
