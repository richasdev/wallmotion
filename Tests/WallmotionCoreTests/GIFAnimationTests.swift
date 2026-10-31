import Foundation
import CoreGraphics
import Darwin
import Testing
@testable import WallmotionCore

@Suite("Immutable GIF animation bridge")
struct GIFAnimationTests {
    private func fixture(profile: Data? = nil, canvas: (UInt16, UInt16) = (1, 1)) -> Data {
        var bytes: [UInt8] = [0x47,0x49,0x46,0x38,0x39,0x61,
            UInt8(truncatingIfNeeded: canvas.0), UInt8(canvas.0 >> 8),
            UInt8(truncatingIfNeeded: canvas.1), UInt8(canvas.1 >> 8),0x80,0,0,0,0,0,255,255,255]
        if let profile {
            bytes += [0x21,0xff,11] + Array("ICCRGBG1012".utf8)
            for start in stride(from: 0, to: profile.count, by: 255) {
                let block = profile[start..<min(profile.count, start+255)]
                bytes.append(UInt8(block.count));bytes += block
            }
            bytes.append(0)
        }
        for (code, delay): (UInt8, UInt8) in [(0x44, 0), (0x4c, 5)] {
            bytes += [0x21,0xf9,4,0,delay,0,0,0]
            bytes += [0x2c,0,0,0,0,1,0,1,0,0,2,2,code,1,0]
        }
        bytes.append(0x3b);return Data(bytes)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let provider = try #require(image.dataProvider)
        let data = try #require(provider.data) as Data
        return Array(data)
    }

    @Test func imageProvidersKeepBothFramesAliveAfterSwiftOwnerIsReleased() throws {
        var animation: GIFAnimation? = try GIFAnimation(data: fixture())
        let weakAnimation = WeakGIFOwner(animation)
        let first = try #require(animation).image(at: 0)
        let second = try #require(animation).image(at: 1)
        animation = nil
        #expect(weakAnimation.value == nil, "CGImage must own native storage independently of its Swift factory.")
        #expect(try pixels(first) == [0,0,0,255])
        #expect(try pixels(second) == [255,255,255,255])
        var rendered = [UInt8](repeating: 0, count: 4)
        try rendered.withUnsafeMutableBytes { storage in
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(second, in: CGRect(x: 0,y: 0,width: 1,height: 1))
        }
        #expect(rendered == [255,255,255,255])
    }

    @Test func metadataDelaysAndInvalidIndicesRemainExact() throws {
        let animation = try GIFAnimation(data: fixture())
        #expect((animation.width, animation.height, animation.frameCount) == (1,1,2))
        #expect(animation.decodedBytes == 8)
        #expect(try animation.delayCentiseconds(at: 0) == 0)
        #expect(try animation.delayCentiseconds(at: 1) == 5)
        for index in [Int.min,-1,2,Int.max] {
            #expect(throws: GIFAnimationError.invalidIndex) { try animation.image(at: index) }
        }
    }

    @Test func rejectsEncodedPixelFrameAndWorkingBudgetsThroughABI() {
        let data = fixture()
        for (limits, status) in [(GIFAnimationLimits(encodedBytes: 1), Int32(4)),
            (.init(decodedBytes: 7), 2), (.init(workingBytes: 12), 2), (.init(frames: 1), 5)] {
            #expect(throws: GIFAnimationError.nativeStatus(status)) { try GIFAnimation(data: data, limits: limits) }
        }
        #expect(throws: GIFAnimationError.nativeStatus(1)) { try GIFAnimation(data: Data()) }
    }

    @Test func rejectsInvalidICCInsteadOfSilentlyChangingItsColorSpace() {
        #expect(throws: GIFAnimationError.invalidColorProfile) { try GIFAnimation(data: fixture(profile: Data("test".utf8))) }
    }

    @Test func validSourceICCProducesRGBImages() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let profile = try #require(space.copyICCData()) as Data
        // Keep the codec's per-buffer admission above this synthetic profile size.
        let height = UInt16(max(1, (profile.count + 63) / 64))
        let animation = try GIFAnimation(data: fixture(profile: profile, canvas: (64,height)))
        let image = try animation.image(at: 0)
        #expect(image.colorSpace?.model == .rgb)
        #expect(image.width == 64)
        #expect(image.height == Int(height))
    }

    @Test func concurrentImagesReadImmutableNativeFrames() async throws {
        let animation = try GIFAnimation(data: fixture())
        try await withThrowingTaskGroup(of: Int.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var count = 0
                    for _ in 0..<40 {
                        let image = try animation.image(at: worker % 2)
                        let data = try #require(image.dataProvider?.data) as Data
                        #expect(Array(data) == (worker % 2 == 0 ? [0,0,0,255] : [255,255,255,255]))
                        count += 1
                    }
                    return count
                }
            }
            var total = 0
            for try await count in group { total += count }
            #expect(total == 320)
        }
    }
    @Test func userFacingFailuresDoNotExposeNativeImplementationNames() {
        let failures: [GIFAnimationError] = [.nativeStatus(1), .nativeStatus(2), .nativeStatus(3),
            .nativeStatus(4), .nativeStatus(5), .nativeStatus(7), .nativeStatus(9),
            .nativeStatus(999), .invalidColorProfile, .imageCreationFailed, .invalidIndex]
        for error in failures {
            #expect(!error.localizedDescription.contains("WallmotionCore"))
            #expect(!error.localizedDescription.contains("nativeStatus"))
            #expect(!error.localizedDescription.contains("999"))
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionGIFFile-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func URLPreparationOwnsFramesAfterSourceIsRemoved() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("source.gif")
            try fixture().write(to: url)
            let animation = try GIFAnimation(url: url)
            try FileManager.default.removeItem(at: url)
            #expect(animation.frameCount == 2)
            #expect(try pixels(animation.image(at: 1)) == [255,255,255,255])
        }
    }

    @Test func URLPreparationRejectsLinksDirectoriesFIFOAndRemoteInputs() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("source.gif")
            let link = root.appendingPathComponent("link.gif")
            let fifo = root.appendingPathComponent("pipe.gif")
            try fixture().write(to: source)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: link) }
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: root) }
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: fifo) }
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: URL(string: "https://example.com/image.gif")!) }
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: URL(string: "file://example.com/image.gif")!) }
        }
    }

    @Test func URLPreparationRejectsEncodedAndFrameLimits() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("source.gif")
            try fixture().write(to: url)
            #expect(throws: GIFAnimationError.nativeStatus(5)) { try GIFAnimation(url: url, limits: .init(frames: 1)) }
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: 1_048_576);try file.close()
            #expect(throws: GIFAnimationError.nativeStatus(4)) { try GIFAnimation(url: url, limits: .init(encodedBytes: 1024)) }
        }
    }

    @Test func localMediaPathsRejectMalformedURLBeforePOSIXOpen() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("source.gif")
            try fixture().write(to: source)
            let truncated = root.appendingPathComponent("source.gif\u{0}ignored")
            #expect(truncated.path.isEmpty || truncated.path.utf8.contains(0))
            #expect(throws: LibraryError.notRegularFile) { try GIFAnimation(url: truncated) }
            #expect(throws: LibraryError.notRegularFile) { try GIFPreflight.inspect(url: truncated) }
        }
    }

}

private final class WeakGIFOwner {
    weak var value: GIFAnimation?
    init(_ value: GIFAnimation?) { self.value = value }
}
