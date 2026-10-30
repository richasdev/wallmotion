# Library process lease primitive

This PR adds a **core primitive only**. The application does not acquire it yet; multi-instance startup/activation and forwarding open-file events remain required under #84. Existing stores/models are not implicitly serialized by this class.

`LibraryProcessLock.acquire(in:)` creates/opens a persistent `wallmotion.lock` entry relative to the library directory and attempts `flock(LOCK_EX | LOCK_NB)`. It returns a retained lease on success, nil when busy, or throws for other failures. It does not wait for a busy owner. Release is idempotent; deinit also closes the descriptor. A small NSLock guards the close transition, and the descriptor is not exposed. The type does not declare unchecked Sendable conformance.

The entry is opened with NOFOLLOW/NONBLOCK/CLOEXEC and exclusive advisory locking. fstat rejects nonregular files, hardlinks and a different owning UID before chmod; the directory entry must still name the opened inode. Successful acquisition sets mode 0600. Busy callers do not truncate or chmod the owner's entry. Newly created directories request mode 0700; existing root permissions remain unchanged.

Do **not** unlink the lock file when releasing or infer liveness from its mere existence. Reusing a persistent inode avoids splitting cooperating callers between an old held inode and a new path. The kernel releases the advisory lock when the last corresponding open reference closes. CLOEXEC prevents this reference surviving ordinary exec-based child launches; raw fork/dup can retain it. The tests demonstrate release after killing a child that owns the only reference.

This is a cooperative local-filesystem protocol, not a security boundary against the same UID, older clients or external writers. The parent path is not pinned before its initial open; ancestry changes and later unlink/replacement by the same account remain possible. Network mounts, inode replacement and unsupported flock behavior need separate treatment. Mode does not override inherited ACL grants. No process identity is read from file contents, and preexisting regular contents are preserved.

## Validation

Five core tests cover exclusive acquisition, mode normalization, explicit/idempotent/deinit release, persistent inode, unchanged existing root mode, normal/broken symlink and hardlink/FIFO refusal, independent-process contention, re-acquisition, and SIGKILL release. Children use `/usr/bin/python3` and temporary paths to exercise BSD flock interoperability; a five-second child alarm bounds fixture failure. Only the test-owned child PID is terminated. No user library or running Wallmotion instance is used.

Reference: [Apple flock(2) manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html).
