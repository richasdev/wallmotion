import Foundation
import Darwin

/// Directory-relative mutations pin Media while an operation is running. URLs
/// returned to AppKit/AVFoundation are still paths, not pinned descriptors.
enum ManagedMediaFiles {
    static func copy(from source: URL, filename: String, kind: MediaKind, root: URL,
                     copyData: (Int32, Int32) throws -> Void = { input, output in
                         guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) == 0 else { throw posixError() }
                     }) throws {
        guard source.isFileURL, [nil, "", "localhost"].contains(source.host) else { throw LibraryError.notRegularFile }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else {
            if errno == ELOOP { throw LibraryError.notRegularFile }
            throw posixError()
        }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LibraryError.notRegularFile }
        guard info.st_size > 0 else { throw LibraryError.emptyMedia }
        if kind == .gif { _ = try GIFPreflight.inspect(descriptor: input) }
        guard let directory = try directory(root: root, create: true) else { throw LibraryError.invalidLocalPath }
        defer { close(directory) }
        let output = openat(directory, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw posixError() }
        defer { close(output) }
        var complete = false
        defer { if !complete { _ = unlinkat(directory, filename, 0) } }
        // Copy bytes and xattrs (including quarantine), without source mode/ACLs.
        // Unlike a path copy, replacement of the source name cannot redirect I/O.
        try copyData(input, output)
        guard fchmod(output, mode_t(0o600)) == 0 else { throw posixError() }
        if kind == .gif { _ = try GIFPreflight.inspect(descriptor: output) }
        var finalInput = stat(), finalOutput = stat()
        guard fstat(input, &finalInput) == 0, fstat(output, &finalOutput) == 0 else { throw posixError() }
        guard finalOutput.st_size == info.st_size,
              finalInput.st_size == info.st_size,
              finalInput.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              finalInput.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              finalInput.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              finalInput.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else { throw LibraryError.mediaChanged }
        // Do not publish an unreachable copy if Media was replaced while copying.
        try verifyCurrentDirectory(directory, root: root)
        complete = true
    }

    static func validate(filename: String, root: URL) throws {
        guard let directory = try directory(root: root, create: false) else { return }
        defer { close(directory) }
        _ = try regularFile(filename: filename, directory: directory)
    }

    static func remove(filename: String, root: URL) throws {
        guard let directory = try directory(root: root, create: false) else { return }
        defer { close(directory) }
        guard try regularFile(filename: filename, directory: directory) else { return }
        // unlinkat removes this directory entry, including a symlink substituted
        // after the check; it cannot follow that symlink to delete its target.
        if unlinkat(directory, filename, 0) != 0, errno != ENOENT { throw posixError() }
    }

    private static func directory(root: URL, create: Bool) throws -> Int32? {
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw posixError()
        }
        defer { close(rootFD) }
        if create, mkdirat(rootFD, "Media", mode_t(0o700)) != 0, errno != EEXIST { throw posixError() }
        let mediaFD = openat(rootFD, "Media", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard mediaFD >= 0 else {
            if !create, errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw LibraryError.invalidLocalPath }
            throw posixError()
        }
        return mediaFD
    }

    private static func regularFile(filename: String, directory: Int32) throws -> Bool {
        var info = stat()
        guard fstatat(directory, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LibraryError.notRegularFile }
        return true
    }

    private static func verifyCurrentDirectory(_ descriptor: Int32, root: URL) throws {
        guard let current = try directory(root: root, create: false) else { throw LibraryError.invalidLocalPath }
        defer { close(current) }
        var old = stat(), new = stat()
        guard fstat(descriptor, &old) == 0, fstat(current, &new) == 0 else { throw posixError() }
        guard old.st_dev == new.st_dev, old.st_ino == new.st_ino else { throw LibraryError.invalidLocalPath }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
