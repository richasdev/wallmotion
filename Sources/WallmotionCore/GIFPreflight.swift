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
    // Complete encoded input, including extensions/trailing data; separate from frames.
    public static let defaultInputBudget: UInt64 = 256 * 1024 * 1024

    public static func inspect(url: URL, maxDecodedBytes: UInt64 = defaultBudget,
                               maxInputBytes: UInt64 = defaultInputBudget) throws -> GIFMetadata {
        try withDescriptor(url: url) {
            try inspect(descriptor: $0, maxDecodedBytes: maxDecodedBytes, maxInputBytes: maxInputBytes)
        }
    }

    /// Fast thumbnail gate: metadata only, not GIF structure/frame validation.
    public static func validateInputSize(url: URL, maxInputBytes: UInt64 = defaultInputBudget) throws {
        try withDescriptor(url: url) { descriptor in
            let status = wm_gif_check_input_fd(descriptor, maxInputBytes)
            guard status != 4 else { throw LibraryError.gifInputTooLarge(limit: maxInputBytes) }
            guard status == 0 else { throw LibraryError.notRegularFile }
        }
    }

    private static func withDescriptor<T>(url: URL, body: (Int32) throws -> T) throws -> T {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host) else { throw LibraryError.notRegularFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw LibraryError.notRegularFile }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        return try body(descriptor)
    }

    /// Bounded Rust read-ahead avoids SIGBUS from mapped pages of a mutable file.
    static func inspect(descriptor: Int32, maxDecodedBytes: UInt64 = defaultBudget, maxInputBytes: UInt64 = defaultInputBudget) throws -> GIFMetadata {
        var info = WMGifInfo()
        let status = wm_gif_probe_fd_limited(descriptor, maxDecodedBytes, maxInputBytes, &info)
        return try metadata(info, status: status, maxDecodedBytes: maxDecodedBytes, maxInputBytes: maxInputBytes)
    }

    public static func inspect(data: Data, maxDecodedBytes: UInt64 = defaultBudget, maxInputBytes: UInt64 = defaultInputBudget) throws -> GIFMetadata {
        var info = WMGifInfo()
        let status = data.withUnsafeBytes { buffer in
            wm_gif_probe_limited(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, maxDecodedBytes, maxInputBytes, &info)
        }
        return try metadata(info, status: status, maxDecodedBytes: maxDecodedBytes, maxInputBytes: maxInputBytes)
    }

    private static func metadata(_ info: WMGifInfo, status: Int32, maxDecodedBytes: UInt64, maxInputBytes: UInt64) throws -> GIFMetadata {
        guard status != 4 else { throw LibraryError.gifInputTooLarge(limit: maxInputBytes) }
        guard status != 3 else { throw LibraryError.gifTooComplex }
        guard status != 2 else { throw LibraryError.gifTooLarge }
        guard status == 0 else { throw LibraryError.invalidGIF }
        guard info.decoded_bytes <= maxDecodedBytes else { throw LibraryError.gifTooLarge }
        return GIFMetadata(width: info.width, height: info.height, frames: info.frames, decodedBytes: info.decoded_bytes)
    }
}
