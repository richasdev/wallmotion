import Foundation
import CoreGraphics

public enum MediaFit: String, Codable, CaseIterable, Sendable {
    case fit, fill, center, stretch

    /// Centered destination rectangle; fill extends beyond the clipping viewport.
    public func frame(for media: CGSize, in bounds: CGRect, backingScale: CGFloat = 1) -> CGRect {
        guard media.width > 0, media.height > 0, bounds.width > 0, bounds.height > 0,
              media.width.isFinite, media.height.isFinite,
              bounds.width.isFinite, bounds.height.isFinite else { return .zero }
        if self == .stretch { return bounds }
        let horizontal = bounds.width / media.width
        let vertical = bounds.height / media.height
        let scale: CGFloat
        switch self {
        case .fit: scale = min(horizontal, vertical)
        case .fill: scale = max(horizontal, vertical)
        case .center: scale = 1 / (backingScale.isFinite && backingScale > 0 ? backingScale : 1)
        case .stretch: scale = 1
        }
        let size = CGSize(width: media.width * scale, height: media.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Longest edge for ImageIO, bounded before decoding in both presentation modes.
    /// Extreme crops retain their geometry but use a lower resolution bitmap.
    public func decodePixelLimit(for media: CGSize, viewport: CGSize) -> Int {
        guard media.width >= 1, media.height >= 1,
              media.width.isFinite, media.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              viewport.width.isFinite, viewport.height.isFinite else { return 1 }
        let horizontal = viewport.width / media.width
        let vertical = viewport.height / media.height
        let scale = self == .center ? 1 : min(1, self == .fit ? min(horizontal, vertical) : max(horizontal, vertical))
        // Clamp while still floating point: even hostile metadata must never overflow Int.
        let requested = Int(ceil(min(CGFloat(PhotoDecodeBudget.maximumDimension), max(media.width, media.height) * scale)))
        var lower = 1
        var upper = max(1, requested)
        while lower < upper {
            let candidate = (lower + upper + 1) / 2
            if PhotoDecodeBudget.estimatedBytes(for: media, pixelLimit: candidate) <= PhotoDecodeBudget.maximumBytes {
                lower = candidate
            } else {
                upper = candidate - 1
            }
        }
        return lower
    }
}

/// Per-photo output budget, not a bound on codec scratch memory or process RSS.
public enum PhotoDecodeBudget {
    public static let maximumBytes = 128 * 1024 * 1024
    public static let maximumDimension = 16_384
    // Conservatively reserve RGBA float32 (16 bytes/pixel), even though the
    // renderer disables floating-point decode. Include 64-byte row alignment.
    private static let bytesPerPixel = 16

    public static func estimatedBytes(for media: CGSize, pixelLimit: Int) -> Int {
        guard media.width >= 1, media.height >= 1,
              media.width.isFinite, media.height.isFinite,
              (1...maximumDimension).contains(pixelLimit) else { return Int.max }
        let longest = max(media.width, media.height)
        let edge = min(CGFloat(pixelLimit), longest)
        let width = max(1, Int(ceil((media.width / longest) * edge)))
        let height = max(1, Int(ceil((media.height / longest) * edge)))
        let rowBytes = ((width * bytesPerPixel + 63) / 64) * 64
        return rowBytes * height
    }
}
