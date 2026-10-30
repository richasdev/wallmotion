import Foundation
import ImageIO
import WallmotionCore

struct PhotoDecodeRequest: Hashable, Sendable {
    let url: URL
    let mediaFit: MediaFit
    let viewportWidth: Double
    let viewportHeight: Double
}

struct DecodedPhoto: Sendable {
    let image: CGImage
    /// Oriented source dimensions remain independent of the bounded bitmap size.
    let sourceSize: CGSize
}

/// One shared serial executor prevents rapid selections and multiple screens from
/// launching simultaneous ImageIO decodes. Cancellation cannot interrupt a codec
/// call already in progress; it prevents queued work and publishing stale output.
actor PhotoDecodeWorker {
    static let shared = PhotoDecodeWorker()
    private let decodeImage: @Sendable (PhotoDecodeRequest) throws -> DecodedPhoto

    init(decodeImage: @escaping @Sendable (PhotoDecodeRequest) throws -> DecodedPhoto = PhotoDecodeWorker.decodeImage) {
        self.decodeImage = decodeImage
    }

    func decode(_ request: PhotoDecodeRequest) throws -> DecodedPhoto {
        try Task.checkCancellation()
        let result = try decodeImage(request)
        try Task.checkCancellation()
        return result
    }

    nonisolated static func decodeImage(_ request: PhotoDecodeRequest) throws -> DecodedPhoto {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue >= 1, height.doubleValue >= 1 else {
            throw PhotoDecodingError.unreadable
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let size = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                          height: rotated ? width.doubleValue : height.doubleValue)
        let limit = request.mediaFit.decodePixelLimit(for: size, viewport: CGSize(
            width: request.viewportWidth, height: request.viewportHeight))
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldAllowFloat: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PhotoDecodingError.unreadable }
        try Task.checkCancellation()
        guard image.width <= limit, image.height <= limit, image.height > 0,
              image.bytesPerRow <= PhotoDecodeBudget.maximumBytes / image.height else {
            throw PhotoDecodingError.overBudget
        }
        return DecodedPhoto(image: image, sourceSize: size)
    }
}

enum PhotoDecodingError: LocalizedError {
    case unreadable, overBudget
    var errorDescription: String? {
        switch self {
        case .unreadable: "Não foi possível decodificar a foto."
        case .overBudget: "A foto decodificada excedeu o limite de memória. Use uma cópia com resolução menor."
        }
    }
}
