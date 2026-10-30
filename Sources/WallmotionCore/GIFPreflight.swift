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
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host) else { throw LibraryError.notRegularFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw LibraryError.notRegularFile }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        return try inspect(descriptor: descriptor, maxDecodedBytes: maxDecodedBytes)
    }

    /// Bounded Rust read-ahead avoids SIGBUS from mapped pages of a mutable file.
    static func inspect(descriptor: Int32, maxDecodedBytes: UInt64 = defaultBudget) throws -> GIFMetadata {
        var info = WMGifInfo()
        let status = wm_gif_probe_fd_bounded(descriptor, maxDecodedBytes, &info)
        return try metadata(info, status: status, maxDecodedBytes: maxDecodedBytes)
    }

    public static func inspect(data: Data, maxDecodedBytes: UInt64 = defaultBudget) throws -> GIFMetadata {
        var info = WMGifInfo()
        let status = data.withUnsafeBytes { buffer in
            wm_gif_probe_bounded(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, maxDecodedBytes, &info)
        }
        return try metadata(info, status: status, maxDecodedBytes: maxDecodedBytes)
    }

    private static func metadata(_ info: WMGifInfo, status: Int32, maxDecodedBytes: UInt64) throws -> GIFMetadata {
        guard status != 2 else { throw LibraryError.gifTooLarge }
        guard status == 0 else { throw LibraryError.invalidGIF }
        guard info.decoded_bytes <= maxDecodedBytes else { throw LibraryError.gifTooLarge }
        return GIFMetadata(width: info.width, height: info.height, frames: info.frames, decodedBytes: info.decoded_bytes)
    }
}
