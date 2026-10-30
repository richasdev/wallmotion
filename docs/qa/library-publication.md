# Private library publication

`library.json` can contain media URLs with query tokens and unlisted embed identifiers. Successful saves now publish a complete replacement with POSIX mode **0600**, including replacement of an older readable file. Existing files are normalized on the next successful save, not by a read-only load.

The writer checks the 16 MiB encoded-input limit before filesystem work, opens the parent directory, and validates the destination entry without following a leaf symlink. It creates an exclusive UUID temporary file relative to that directory with `O_NOFOLLOW | O_CLOEXEC`, enforces mode 0600 on the descriptor, writes all bytes (retrying EINTR and partial writes), validates the destination again, and uses same-directory `renameat` to publish atomically. Failure before publication leaves the previous destination and attempts to unlink the temporary file. Readers opening the destination see the old or new file, rather than the partially written temporary file.

This is atomic visibility, not a power-loss durability guarantee: no `fsync` or `F_FULLFSYNC` is added to frequent UI preference saves. OS/volume errors can still prevent temporary-file cleanup. The directory descriptor pins the directory after opening; ancestors and concurrent same-UID path changes are not a sandbox. POSIX mode does not override inherited ACL grants or isolate processes sharing the account. Directory permissions and parent traversal determine whether a previously readable file was actually accessible by another UID. Existing parent-directory permissions are preserved.

## Reproduction and validation

A disposable fixture wrote an existing library with mode 0644. Before the fix, saving retained decimal mode 420 (0644), failing the required 384 (0600) assertion. After the fix, replacement and first-save mode checks pass, saved JSON round-trips, and no temporary file remains after success.

Regression tests also exercise normal/broken symlink destinations without changing the referenced target, FIFO/directory rejection without blocking, and oversized payload rejection preserving the original bytes. Existing library validation and corrupt-library read-only behavior remain covered. These tests use temporary directories and do not inspect or change the user's library. Disk-full, power-loss and concurrent malicious directory replacement are not simulated.
