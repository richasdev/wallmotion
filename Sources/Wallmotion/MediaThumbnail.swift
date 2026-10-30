import AVFoundation
import ImageIO
import SwiftUI
import WallmotionCore

@MainActor
private enum ThumbnailCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()

    static func key(_ url: URL, width: Int, height: Int) -> NSString { "\(url.path)#\(width)x\(height)" as NSString }
}

struct MediaThumbnail: View {
    let item: Wallpaper
    let localURL: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let size = pixelDimensions(for: geometry.size)
            let cacheKey = localURL.map { ThumbnailCache.key($0, width: size.width, height: size.height) }
            ZStack {
                LinearGradient(colors: [.accentColor.opacity(0.25), .indigo.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: fallbackSymbol).font(.system(size: 38, weight: .light)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: ThumbnailRequest(url: localURL, kind: item.kind.rawValue, width: size.width, height: size.height)) {
                await loadThumbnail(width: size.width, height: size.height, cacheKey: cacheKey)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func pixelDimensions(for size: CGSize) -> (width: Int, height: Int) {
        (max(1, Int((size.width * displayScale).rounded(.up))), max(1, Int((size.height * displayScale).rounded(.up))))
    }

    private var fallbackSymbol: String {
        switch item.kind {
        case .image: "photo"
        case .gif: "square.stack.3d.up"
        case .video: "play.rectangle"
        }
    }

    @MainActor
    private func loadThumbnail(width: Int, height: Int, cacheKey: NSString?) async {
        image = nil
        guard let localURL, let cacheKey else { return }
        if let cached = ThumbnailCache.images.object(forKey: cacheKey) { image = cached; return }
        let kind = item.kind
        do {
            let generation = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                switch kind {
                case .image, .gif:
                    guard let result = MediaThumbnailDecoding.imageThumbnail(url: localURL, targetWidth: width, targetHeight: height) else { throw ThumbnailError.unavailable }
                    try Task.checkCancellation()
                    return result
                case .video:
                    let worker = VideoThumbnailGenerator(url: localURL, targetWidth: width, targetHeight: height)
                    let result = try await withTaskCancellationHandler {
                        try await worker.generate()
                    } onCancel: {
                        worker.cancel()
                    }
                    try Task.checkCancellation()
                    return result
                }
            }
            let cgImage = try await withTaskCancellationHandler {
                try await generation.value
            } onCancel: {
                generation.cancel()
            }
            try Task.checkCancellation()
            let result = NSImage(cgImage: cgImage, size: .zero)
            ThumbnailCache.images.setObject(result, forKey: cacheKey, cost: cgImage.bytesPerRow * cgImage.height)
            image = result
        } catch is CancellationError {
            // A recycled or resized card no longer needs this result.
        } catch {
            image = nil
        }
    }
}

private struct ThumbnailRequest: Hashable {
    let url: URL?
    let kind: String
    let width: Int
    let height: Int
}

enum MediaThumbnailDecoding {
    static func imageThumbnail(url: URL, targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let orientedWidth = swapsAxes ? sourceHeight : sourceWidth
        let orientedHeight = swapsAxes ? sourceWidth : sourceHeight
        let maximumPixelSize = aspectFillMaximumPixelSize(
            sourceWidth: orientedWidth, sourceHeight: orientedHeight,
            targetWidth: targetWidth, targetHeight: targetHeight
        )
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    static func aspectFillMaximumPixelSize(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int) -> Int {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else { return 1 }
        let scale = max(Double(targetWidth) / Double(sourceWidth), Double(targetHeight) / Double(sourceHeight))
        let desired = Double(max(sourceWidth, sourceHeight)) * scale
        guard desired < 4096 else { return 4096 }
        return max(1, min(max(sourceWidth, sourceHeight), Int(desired.rounded(.up))))
    }
}

private enum ThumbnailError: Error { case unavailable }

private final class VideoThumbnailGenerator: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    private let targetWidth: Int
    private let targetHeight: Int

    init(url: URL, targetWidth: Int, targetHeight: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
    }

    func generate() async throws -> CGImage {
        if let track = try await generator.asset.loadTracks(withMediaType: .video).first {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let size = CGRect(origin: .zero, size: naturalSize.applying(transform)).standardized.size
            let maximumPixelSize = MediaThumbnailDecoding.aspectFillMaximumPixelSize(
                sourceWidth: Int(abs(size.width)), sourceHeight: Int(abs(size.height)),
                targetWidth: targetWidth, targetHeight: targetHeight
            )
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        } else {
            generator.maximumSize = CGSize(width: max(targetWidth, targetHeight), height: max(targetWidth, targetHeight))
        }
        return try await generator.image(at: .zero).image
    }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
