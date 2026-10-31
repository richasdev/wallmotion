import Foundation
import CoreGraphics

/// A photo or GIF placed once in AppKit's global point coordinates. Each screen clips
/// its slice without re-decoding the image. Gaps between screens consume space.
public struct PanoramaLayout: Equatable, Sendable {
    public let bounds: CGRect
    public let referenceScale: CGFloat
    public var pixelSize: CGSize {
        CGSize(width: bounds.width * referenceScale, height: bounds.height * referenceScale)
    }

    public init?(frames: [CGRect], backingScales: [CGFloat]) {
        guard !frames.isEmpty, frames.count == backingScales.count,
              frames.allSatisfy({ frame in
                  [frame.origin.x, frame.origin.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
                      && !frame.isInfinite && !frame.isNull && frame.width > 0 && frame.height > 0
              }), backingScales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let scale = backingScales.max() ?? 1
        guard [union.origin.x, union.origin.y, union.width, union.height, union.maxX, union.maxY,
               union.width * scale, union.height * scale].allSatisfy(\.isFinite),
              union.width > 0, union.height > 0 else { return nil }
        bounds = union
        referenceScale = scale
    }

    public func imageFrame(sourcePixels: CGSize, fit: MediaFit, on screen: CGRect) -> CGRect {
        let logicalSize = CGSize(width: sourcePixels.width / referenceScale, height: sourcePixels.height / referenceScale)
        return fit.frame(for: logicalSize, in: bounds).offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
}
