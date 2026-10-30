import Foundation
import Darwin

/// Advisory lease for cooperating local processes. Holding this object alone
/// does not protect a store: the application must acquire it before model work.
public final class LibraryProcessLock {
    private let gate = NSLock()
    private var descriptor: Int32?
    private let rootURL: URL
    public static let filename = "wallmotion.lock"

    private init(descriptor: Int32, rootURL: URL) { self.descriptor = descriptor; self.rootURL = rootURL }
    deinit { release() }

    /// nil means another cooperating process holds this inode's lock.
    public static func acquire(in root: URL) throws -> LibraryProcessLock? {
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host) else { throw LibraryLockError.invalidFile }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { close(directory) }
        let file = openat(directory, filename, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else {
            if errno == ELOOP { throw LibraryLockError.invalidFile }
            throw posixError()
        }
        var transferred = false
        defer { if !transferred { close(file) } }
        try validate(file: file, directory: directory)
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return nil }
            throw posixError()
        }
        // A busy caller does not chmod/truncate or change the owner's metadata.
        guard fchmod(file, mode_t(0o600)) == 0 else { throw posixError() }
        try validate(file: file, directory: directory)
        transferred = true
        return LibraryProcessLock(descriptor: file, rootURL: root)
    }

    /// Publish only while this lease is held. A separate atomic identity file
    /// avoids exposing a partially written PID. Readers must still verify OS
    /// identity and liveness rather than trusting a persisted record.
    public func publishIdentity(_ identity: LibraryProcessIdentity) throws {
        gate.lock()
        defer { gate.unlock() }
        guard let file = descriptor else { throw LibraryLockError.notHeld }
        let directory = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posixError() }
        defer { close(directory) }
        try Self.validate(file: file, directory: directory)
        try identity.validated()
        try LibraryStateFile.write(JSONEncoder().encode(identity), at: rootURL.appendingPathComponent(LibraryProcessIdentity.filename))
    }

    /// Idempotent. Never unlink the inode used by other cooperating openers.
    public func release() {
        gate.lock()
        defer { gate.unlock() }
        guard let file = descriptor else { return }
        descriptor = nil
        // A transient fork/exec child can still hold a duplicate reference until
        // CLOEXEC runs. Explicit unlock releases our shared open description now.
        while flock(file, LOCK_UN) != 0 {
            if errno != EINTR { break }
        }
        _ = close(file)
    }

    private static func validate(file: Int32, directory: Int32) throws {
        var opened = stat(), current = stat()
        guard fstat(file, &opened) == 0 else { throw posixError() }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              opened.st_nlink == 1, opened.st_uid == getuid() else { throw LibraryLockError.invalidFile }
        guard fstatat(directory, filename, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
        guard current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else { throw LibraryLockError.invalidFile }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

public enum LibraryLockError: LocalizedError, Equatable {
    case invalidFile, notHeld
    public var errorDescription: String? {
        switch self {
        case .invalidFile: "O arquivo de controle da biblioteca precisa ser um arquivo comum desta conta, sem links."
        case .notHeld: "A trava da biblioteca já foi liberada."
        }
    }
}
