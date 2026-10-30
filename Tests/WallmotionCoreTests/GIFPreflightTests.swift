import Foundation
import Testing
@testable import WallmotionCore

@Suite("GIF preflight through Rust FFI")
struct GIFPreflightTests {
    // 1x1 GIF89a with a real two-color palette and LZW image data.
    private func fixture(frames: Int = 1) -> Data {
        var bytes: [UInt8] = [
            0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
            1, 0, 1, 0, 0x80, 0, 0,
            0, 0, 0, 0xff, 0xff, 0xff
        ]
        let image: [UInt8] = [0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 1, 0]
        for _ in 0..<frames {
            bytes += [0x21, 0xf9, 4, 0, 10, 0, 0, 0]
            bytes += image
        }
        bytes.append(0x3b)
        return Data(bytes)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionGIFTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test(arguments: [1, 2])
    func reportsRealGIFMetadata(_ frames: Int) throws {
        let metadata = try GIFPreflight.inspect(data: fixture(frames: frames))
        #expect(metadata.width == 1)
        #expect(metadata.height == 1)
        #expect(metadata.frames == UInt32(frames))
        #expect(metadata.decodedBytes == UInt64(4 * frames))
    }

    @Test(arguments: [1, 2])
    func acceptsExactBudgetAndRejectsOneByteLess(_ frames: Int) throws {
        let data = fixture(frames: frames)
        let exact = UInt64(4 * frames)
        let metadata = try GIFPreflight.inspect(data: data, maxDecodedBytes: exact)
        #expect(metadata.decodedBytes == exact)
        #expect(throws: LibraryError.gifTooLarge) {
            try GIFPreflight.inspect(data: data, maxDecodedBytes: exact - 1)
        }
    }

    @Test func rejectsEveryTruncatedPrefixAndMalformedHeaders() {
        let valid = fixture(frames: 2)
        for end in 0..<valid.count {
            #expect(throws: LibraryError.invalidGIF) {
                try GIFPreflight.inspect(data: Data(valid.prefix(end)))
            }
        }
        var wrongHeader = valid
        wrongHeader[0] = 0
        #expect(throws: LibraryError.invalidGIF) { try GIFPreflight.inspect(data: wrongHeader) }
        #expect(throws: LibraryError.invalidGIF) { try GIFPreflight.inspect(data: fixture(frames: 0)) }
        var zeroCanvas = valid
        zeroCanvas[6] = 0
        #expect(throws: LibraryError.invalidGIF) { try GIFPreflight.inspect(data: zeroCanvas) }
    }

    @Test func mappedURLInspectionMatchesInMemoryInspectionWithoutChangingSource() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("animation.gif")
            let data = fixture(frames: 2)
            try data.write(to: url)
            let mapped = try GIFPreflight.inspect(url: url, maxDecodedBytes: 8)
            let memory = try GIFPreflight.inspect(data: data)
            #expect(mapped == memory)
            #expect(try Data(contentsOf: url) == data)
            #expect(throws: LibraryError.gifTooLarge) { try GIFPreflight.inspect(url: url, maxDecodedBytes: 7) }
        }
    }

    @Test func rejectsInvalidGIFBeforeCreatingLibraryOrCopy() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("invalid.gif")
            let bytes = Data("not a GIF".utf8)
            try bytes.write(to: source)
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            #expect(throws: LibraryError.invalidGIF) { try store.importFile(at: source) }
            #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
            #expect(try Data(contentsOf: source) == bytes)
        }
    }

    @Test func rejectsExcessiveCanvasEstimateBeforeCopyWithoutDecodingPixels() throws {
        try withTemporaryDirectory { directory in
            // Tiny encoded payload, huge canvas: 8193 * 8192 * 4 > 256 MiB.
            // The scanner must account for the full canvas, not just the 1x1 frame.
            var data = fixture()
            data.replaceSubrange(6..<10, with: [0x01, 0x20, 0x00, 0x20])
            let unrestricted = try GIFPreflight.inspect(data: data, maxDecodedBytes: UInt64.max)
            #expect(unrestricted.decodedBytes == 8193 * 8192 * 4)
            #expect(unrestricted.decodedBytes > GIFPreflight.defaultBudget)
            let source = directory.appendingPathComponent("large.gif")
            try data.write(to: source)
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            #expect(throws: LibraryError.gifTooLarge) { try store.importFile(at: source) }
            #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
            #expect(try Data(contentsOf: source) == data)
        }
    }

    @Test func validAnimatedGIFStillImportsAndPreservesBytes() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("animation.gif")
            let bytes = fixture(frames: 2)
            try bytes.write(to: source)
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            let item = try store.importFile(at: source)
            #expect(item.kind == .gif)
            let copiedURL = try store.resolvedURL(for: item)
            #expect(copiedURL != source)
            #expect(try Data(contentsOf: copiedURL) == bytes)
            #expect(try Data(contentsOf: source) == bytes)
        }
    }
}
