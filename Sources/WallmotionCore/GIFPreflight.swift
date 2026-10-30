import Foundation
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
