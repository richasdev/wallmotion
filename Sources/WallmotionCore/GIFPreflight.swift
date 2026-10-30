import Foundation
import Darwin
import CWallmotionMedia

public struct GIFMetadata: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let frames: UInt32
    public let decodedBytes: UInt64
}

public enum GIFPreflight {
    // Conservative decoded-frame budget per GIF, not a promise of actual RSS.
    public static let defaultBudget: UInt64 = 256 * 1024 * 1024

    public static func inspect(url: URL, maxDecodedBytes: UInt64 = defaultBudget) throws -> GIFMetadata {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try inspect(data: data, maxDecodedBytes: maxDecodedBytes)
    }

    /// Inspect the opened file rather than reopening a mutable source pathname.
    static func inspect(descriptor: Int32, maxDecodedBytes: UInt64 = defaultBudget) throws -> GIFMetadata {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= Int.max else { throw LibraryError.invalidGIF }
        let count = Int(info.st_size)
        guard let bytes = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0), bytes != MAP_FAILED else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { munmap(bytes, count) }
        return try inspect(data: Data(bytesNoCopy: bytes, count: count, deallocator: .none), maxDecodedBytes: maxDecodedBytes)
    }

    public static func inspect(data: Data, maxDecodedBytes: UInt64 = defaultBudget) throws -> GIFMetadata {
        var info = WMGifInfo()
        let status = data.withUnsafeBytes { buffer in
            wm_gif_probe_bounded(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, maxDecodedBytes, &info)
        }
        guard status != 2 else { throw LibraryError.gifTooLarge }
        guard status == 0 else { throw LibraryError.invalidGIF }
        guard info.decoded_bytes <= maxDecodedBytes else { throw LibraryError.gifTooLarge }
        return GIFMetadata(width: info.width, height: info.height, frames: info.frames, decodedBytes: info.decoded_bytes)
    }
}
