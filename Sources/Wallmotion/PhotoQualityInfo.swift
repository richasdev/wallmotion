import Foundation

/// Pixel dimensions of the installed photo, without retaining its bitmap or URL.
struct PhotoQualityInfo: Equatable, Sendable {
    let wallpaperID: UUID
    let sourceWidth: Int
    let sourceHeight: Int
    let bitmapWidth: Int
    let bitmapHeight: Int
    let isPanorama: Bool

    init?(wallpaperID: UUID, sourceSize: CGSize, bitmapWidth: Int, bitmapHeight: Int, isPanorama: Bool) {
        let dimensions = [sourceSize.width, sourceSize.height]
        guard dimensions.allSatisfy({ $0.isFinite && $0 >= 1 && $0 < CGFloat(Int.max) && $0.rounded(.towardZero) == $0 }),
              bitmapWidth > 0, bitmapHeight > 0 else { return nil }
        self.wallpaperID = wallpaperID
        sourceWidth = Int(sourceSize.width)
        sourceHeight = Int(sourceSize.height)
        self.bitmapWidth = bitmapWidth
        self.bitmapHeight = bitmapHeight
        self.isPanorama = isPanorama
    }

    var isReduced: Bool { bitmapWidth < sourceWidth || bitmapHeight < sourceHeight }
}
