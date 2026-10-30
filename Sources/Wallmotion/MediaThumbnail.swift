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

    private func pixelDimensions(for size: CGSize) -> ThumbnailPixelSize {
        ThumbnailPixelSize(points: size, scale: displayScale)
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
        do {
            let cgImage = try await ThumbnailScheduler.shared.image(for: ThumbnailRequest(
                url: localURL, kind: item.kind.rawValue, width: width, height: height))
            try Task.checkCancellation()
            guard let cost = ThumbnailBudget.cost(of: cgImage) else { throw ThumbnailError.unavailable }
            let result = NSImage(cgImage: cgImage, size: .zero)
            ThumbnailCache.images.setObject(result, forKey: cacheKey, cost: cost)
            image = result
        } catch is CancellationError {
            // A recycled or resized card no longer needs this result.
        } catch {
            if !Task.isCancelled { image = nil }
        }
    }
}

struct ThumbnailRequest: Hashable, Sendable {
    let url: URL?
    let kind: String
    let width: Int
    let height: Int
}

enum MediaThumbnailDecoding {
    static func generate(_ request: ThumbnailRequest) async throws -> CGImage {
        try Task.checkCancellation()
        guard let url = request.url, url.isFileURL, [nil, "", "localhost"].contains(url.host),
              let kind = MediaKind(rawValue: request.kind) else { throw ThumbnailError.unavailable }
        switch kind {
        case .image, .gif:
            return try autoreleasepool {
                guard let image = imageThumbnail(url: url, targetWidth: request.width, targetHeight: request.height) else { throw ThumbnailError.unavailable }
                return image
            }
        case .video:
            let worker = VideoThumbnailGenerator(url: url, targetWidth: request.width, targetHeight: request.height)
            return try await withTaskCancellationHandler {
                try await worker.generate()
            } onCancel: { worker.cancel() }
        }
    }

    static func imageThumbnail(url: URL, targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard url.isFileURL, [nil, "", "localhost"].contains(url.host),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let orientedSize = CGSize(width: swapsAxes ? sourceHeight.doubleValue : sourceWidth.doubleValue,
                                  height: swapsAxes ? sourceWidth.doubleValue : sourceHeight.doubleValue)
        guard ThumbnailBudget.validSource(orientedSize) else { return nil }
        let maximumPixelSize = ThumbnailBudget.pixelLimit(source: orientedSize, target: CGSize(width: targetWidth, height: targetHeight))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ] as CFDictionary), ThumbnailBudget.cost(of: image) != nil else { return nil }
        return image
    }

    static func aspectFillMaximumPixelSize(sourceWidth: Int, sourceHeight: Int, targetWidth: Int, targetHeight: Int) -> Int {
        ThumbnailBudget.pixelLimit(source: CGSize(width: sourceWidth, height: sourceHeight), target: CGSize(width: targetWidth, height: targetHeight))
    }
}

enum ThumbnailError: Error, Equatable { case unavailable }

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
            guard ThumbnailBudget.validSource(size) else { throw ThumbnailError.unavailable }
            let maximumPixelSize = ThumbnailBudget.pixelLimit(source: size, target: CGSize(width: targetWidth, height: targetHeight))
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        } else {
            let fallback = ThumbnailBudget.pixelLimit(source: CGSize(width: ThumbnailBudget.maximumDimension, height: ThumbnailBudget.maximumDimension),
                target: CGSize(width: targetWidth, height: targetHeight))
            generator.maximumSize = CGSize(width: fallback, height: fallback)
        }
        try Task.checkCancellation()
        let image = try await generator.image(at: .zero).image
        guard ThumbnailBudget.cost(of: image) != nil else { throw ThumbnailError.unavailable }
        return image
    }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
