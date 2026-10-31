import Foundation
import Darwin

/// Identity observations for admission/invalidation; not an atomic file snapshot.
public struct GIFFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public var resourceKey: String {
        "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
    }

    public static func read(url: URL) throws -> Self {
        try GIFPreflight.withDescriptor(url: url) { try read(descriptor: $0) }
    }

    static func read(descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw LibraryError.notRegularFile
        }
        return Self(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino, size: UInt64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}
