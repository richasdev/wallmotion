import AVFoundation
import ImageIO
import SwiftUI
import WallmotionCore

@MainActor
enum ThumbnailCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()

    static func purge() { images.removeAllObjects() }

    static func key(_ url: URL, kind: String, width: Int, height: Int) -> NSString { "\(url.path)#\(kind)#\(width)x\(height)" as NSString }
}

struct MediaThumbnail: View {
    let item: Wallpaper
    let localURL: URL?
    var compact = false
    @Environment(\.displayScale) private var displayScale
    @State private var presentation = ThumbnailPresentation()

    var body: some View {
        GeometryReader { geometry in
            let size = pixelDimensions(for: geometry.size)
            let cacheKey = localURL.map { ThumbnailCache.key($0, kind: item.kind.rawValue, width: size.width, height: size.height) }
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image = presentation.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: fallbackSymbol).font(.system(size: compact ? 20 : 28, weight: .light))
                        if !compact { Text("Sem prévia").font(.caption.weight(.medium)) }
                    }
                    .foregroundStyle(.secondary).padding(compact ? 8 : 14)
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
        ThumbnailPixelSize(points: size, scale: displayScale).bucketed
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
        guard !Task.isCancelled else { return }
        let request = ThumbnailRequest(url: localURL, kind: item.kind.rawValue, width: width, height: height)
        presentation.begin(request)
        guard localURL != nil, let cacheKey else { return }
        if let cached = ThumbnailCache.images.object(forKey: cacheKey) {
            presentation.publish(cached, for: request)
            return
        }
        do {
            let cgImage = try await ThumbnailScheduler.shared.image(for: request)
            try Task.checkCancellation()
            guard let cost = ThumbnailBudget.cost(of: cgImage) else { throw ThumbnailError.unavailable }
            let result = NSImage(cgImage: cgImage, size: .zero)
            ThumbnailCache.images.setObject(result, forKey: cacheKey, cost: cost)
            presentation.publish(result, for: request)
        } catch is CancellationError {
            // A recycled or resized card no longer needs this result.
        } catch {
            // Keep a prepared image of the same asset during a failed resize.
            // begin already cleared it if the media source changed.
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
            if kind == .gif { try GIFPreflight.validateInputSize(url: url) }
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
