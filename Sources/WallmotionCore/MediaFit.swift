import Foundation
import CoreGraphics

public enum MediaFit: String, Codable, CaseIterable, Sendable {
    case fit, fill

    /// Centered destination rectangle; fill extends beyond the clipping viewport.
    public func frame(for media: CGSize, in bounds: CGRect) -> CGRect {
        guard media.width > 0, media.height > 0, bounds.width > 0, bounds.height > 0,
              media.width.isFinite, media.height.isFinite,
              bounds.width.isFinite, bounds.height.isFinite else { return .zero }
        let horizontal = bounds.width / media.width
        let vertical = bounds.height / media.height
        let scale = self == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
        let size = CGSize(width: media.width * scale, height: media.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// ImageIO's longest-edge limit, capped at source resolution (no upsampling).
    public func decodePixelLimit(for media: CGSize, viewport: CGSize) -> Int {
        guard media.width > 0, media.height > 0,
              media.width.isFinite, media.height.isFinite else { return 1 }
        let destination = frame(for: media, in: CGRect(origin: .zero, size: viewport))
        return max(1, Int(ceil(min(max(media.width, media.height), max(destination.width, destination.height)))))
    }
}
