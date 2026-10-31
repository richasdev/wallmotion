import Foundation
import CoreGraphics
import CWallmotionMedia

public struct GIFAnimationLimits: Sendable {
    public var encodedBytes: UInt64
    public var decodedBytes: UInt64
    public var workingBytes: UInt64
    public var frames: UInt32
    public init(encodedBytes: UInt64 = 256 * 1024 * 1024, decodedBytes: UInt64 = 256 * 1024 * 1024,
                workingBytes: UInt64 = 384 * 1024 * 1024, frames: UInt32 = 10_000) {
        self.encodedBytes = encodedBytes; self.decodedBytes = decodedBytes
        self.workingBytes = workingBytes; self.frames = frames
    }
}

public enum GIFAnimationError: Error, Equatable {
    case nativeStatus(Int32)
    case invalidColorProfile
    case invalidIndex
    case imageCreationFailed
}

/// Immutable Rust allocation with thread-safe native reference counts. No mutable
/// Swift state or shared transport. Synchronous decode belongs on a preparation worker.
public final class GIFAnimation: @unchecked Sendable {
    private let handle: OpaquePointer
    private let colorSpace: CGColorSpace
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let decodedBytes: UInt64
    public let repeatCount: UInt16
    public let repeatsInfinitely: Bool

    public convenience init(data: Data, limits: GIFAnimationLimits = .init()) throws {
        var result: OpaquePointer?
        let status = data.withUnsafeBytes { bytes in
            wm_gif_animation_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                limits.encodedBytes, limits.decodedBytes, limits.workingBytes, limits.frames, &result)
        }
        guard status == 0, let native = result else { throw GIFAnimationError.nativeStatus(status) }
        try self.init(ownedHandle: native)
    }

    /// Pinned no-follow descriptor; regular-file/size/stability admission is native.
    /// No mmap/full encoded copy and no file survives this synchronous preparation.
    public convenience init(url: URL, limits: GIFAnimationLimits = .init()) throws {
        let native = try GIFPreflight.withDescriptor(url: url) { descriptor in
            var result: OpaquePointer?
            let status = wm_gif_animation_decode_fd(descriptor, limits.encodedBytes, limits.decodedBytes,
                limits.workingBytes, limits.frames, &result)
            guard status == 0, let handle = result else { throw GIFAnimationError.nativeStatus(status) }
            return handle
        }
        try self.init(ownedHandle: native)
    }

    private init(ownedHandle native: OpaquePointer) throws {
        var transferred = false
        defer { if !transferred { wm_gif_animation_release(native) } }
        var info = WMGifAnimationInfo()
        let infoStatus = wm_gif_animation_info(native, &info)
        guard infoStatus == 0 else { throw GIFAnimationError.nativeStatus(infoStatus) }
        var profile = WMGifByteView()
        let profileStatus = wm_gif_animation_icc(native, &profile)
        guard profileStatus == 0 else { throw GIFAnimationError.nativeStatus(profileStatus) }
        let space: CGColorSpace
        if profile.length > 0 {
            guard let bytes = profile.bytes else { throw GIFAnimationError.invalidColorProfile }
            // Only bounded profile metadata is copied; providers borrow RGBA pixels.
            let copy = Data(bytes: bytes, count: profile.length) as CFData
            guard let parsed = CGColorSpace(iccData: copy), parsed.model == .rgb else {
                throw GIFAnimationError.invalidColorProfile
            }
            space = parsed
        } else {
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw GIFAnimationError.invalidColorProfile }
            space = srgb
        }
        handle = native; colorSpace = space
        width = Int(info.width); height = Int(info.height); frameCount = Int(info.frames)
        decodedBytes = info.decoded_bytes
        repeatCount = info.repeat_count; repeatsInfinitely = info.repeat_infinite != 0
        transferred = true
    }

    deinit { wm_gif_animation_release(handle) }

    public func delayCentiseconds(at index: Int) throws -> UInt16 {
        try withExtendedLifetime(self) { try frame(at: index).delay_centiseconds }
    }

    /// The CGImage's provider owns a native reference independently of this object.
    /// Several images can point at the same immutable bytes without another decode.
    public func image(at index: Int) throws -> CGImage {
        try withExtendedLifetime(self) {
            let view = try frame(at: index)
            guard let pixels = view.pixels, let retained = wm_gif_animation_retain(handle) else {
                throw GIFAnimationError.imageCreationFailed
            }
            guard let provider = CGDataProvider(dataInfo: UnsafeMutableRawPointer(retained), data: pixels,
                size: view.length, releaseData: { info, _, _ in
                    if let info { wm_gif_animation_release(OpaquePointer(info)) }
                }) else {
                wm_gif_animation_release(retained)
                throw GIFAnimationError.imageCreationFailed
            }
            let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big)
            guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmap, provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw GIFAnimationError.imageCreationFailed
            }
            return image
        }
    }

    private func frame(at index: Int) throws -> WMGifFrameView {
        guard index >= 0, index < frameCount, let nativeIndex = UInt32(exactly: index) else {
            throw GIFAnimationError.invalidIndex
        }
        var view = WMGifFrameView()
        let status = wm_gif_animation_frame(handle, nativeIndex, &view)
        guard status == 0 else { throw GIFAnimationError.nativeStatus(status) }
        return view
    }
}
