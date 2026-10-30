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

    static func key(_ url: URL, pixels: Int) -> NSString { "\(url.path)#\(pixels)" as NSString }
}

struct MediaThumbnail: View {
    let item: Wallpaper
    let localURL: URL?
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?

    private var pixelSize: Int { max(1, Int((230 * displayScale).rounded(.up))) }
    private var cacheKey: NSString? { localURL.map { ThumbnailCache.key($0, pixels: pixelSize) } }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.accentColor.opacity(0.25), .indigo.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: 38, weight: .light)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity).clipped()
        .task(id: cacheKey as String?) { await loadThumbnail() }
    }

    private var fallbackSymbol: String {
        switch item.kind {
        case .image: "photo"
        case .gif: "square.stack.3d.up"
        case .video: "play.rectangle"
        }
    }

    @MainActor
    private func loadThumbnail() async {
        image = nil
        guard let localURL, let cacheKey else { return }
        if let cached = ThumbnailCache.images.object(forKey: cacheKey) { image = cached; return }
        let kind = item.kind
        let pixels = pixelSize
        do {
            let generation = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                switch kind {
                case .image, .gif:
                    guard let source = CGImageSourceCreateWithURL(localURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                          CGImageSourceGetCount(source) > 0,
                          let result = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: pixels,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { throw ThumbnailError.unavailable }
                    try Task.checkCancellation()
                    return result
                case .video:
                    let worker = VideoThumbnailGenerator(url: localURL, maximumPixelSize: pixels)
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

private enum ThumbnailError: Error { case unavailable }

private final class VideoThumbnailGenerator: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(url: URL, maximumPixelSize: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
    }

    func generate() async throws -> CGImage { try await generator.image(at: .zero).image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
