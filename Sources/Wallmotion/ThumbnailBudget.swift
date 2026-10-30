import CoreGraphics
import Foundation
import WallmotionCore

struct ThumbnailPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    /// Round upward so resizing within one bucket reuses a request without
    /// asking for fewer pixels than the bounded display geometry requires.
    var bucketed: Self {
        func bucket(_ value: Int) -> Int { min(ThumbnailBudget.maximumDimension, ((value + 31) / 32) * 32) }
        return Self(width: bucket(width), height: bucket(height))
    }

    private init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    init(points: CGSize, scale: CGFloat) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        func bounded(_ value: CGFloat) -> Int {
            guard value.isFinite, value > 0 else { return 1 }
            return max(1, Int(min(CGFloat(ThumbnailBudget.maximumDimension), (value * scale).rounded(.up))))
        }
        width = bounded(points.width)
        height = bounded(points.height)
    }
}

enum ThumbnailBudget {
    static let maximumDimension = 4096
    static let maximumBytes = 8 * 1024 * 1024

    static func validSource(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 1 && size.height >= 1
    }

    /// Preserve aspect-fill detail until the conservative 16 Bpp output budget
    /// is reached. This bounds the prepared bitmap, not codec scratch or RSS.
    static func pixelLimit(source: CGSize, target: CGSize) -> Int {
        guard validSource(source), validSource(target) else { return 1 }
        let scale = max(target.width / source.width, target.height / source.height)
        let longest = max(source.width, source.height)
        let requested = max(1, Int(min(CGFloat(maximumDimension), longest, (longest * scale).rounded(.up))))
        var lower = 1, upper = requested
        while lower < upper {
            let candidate = (lower + upper + 1) / 2
            if PhotoDecodeBudget.estimatedBytes(for: source, pixelLimit: candidate) <= maximumBytes {
                lower = candidate
            } else { upper = candidate - 1 }
        }
        return lower
    }

    static func cost(of image: CGImage) -> Int? {
        guard image.width > 0, image.height > 0,
              image.width <= maximumDimension, image.height <= maximumDimension,
              image.bytesPerRow > 0, image.bytesPerRow <= maximumBytes / image.height else { return nil }
        return image.bytesPerRow * image.height
    }
}
