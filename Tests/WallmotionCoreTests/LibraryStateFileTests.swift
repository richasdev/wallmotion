import Foundation
import Darwin
import Testing
@testable import WallmotionCore

@Suite("Bounded library file loading")
struct LibraryStateFileTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionBoundedState-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func missingAndExactLimitFilesAreHandledWithoutTruncation() throws {
        try fixture { root in
            let file = root.appendingPathComponent("library.json")
            #expect(try LibraryStateFile.read(at: file, maximumBytes: 8) == nil)
            let bytes = Data("12345678".utf8)
            try bytes.write(to: file)
            #expect(try LibraryStateFile.read(at: file, maximumBytes: 8) == bytes)
            #expect(throws: LibraryError.libraryTooLarge) { try LibraryStateFile.read(at: file, maximumBytes: 7) }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func symlinksIncludingDanglingLinksAreRejectedWithoutFollowingTarget() throws {
        try fixture { root in
            let target = root.appendingPathComponent("target.json")
            let file = root.appendingPathComponent("library.json")
            let bytes = try JSONEncoder().encode(LibraryState())
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            #expect(throws: LibraryError.notRegularLibrary) { try LibraryStore(rootURL: root).load() }
            #expect(try Data(contentsOf: target) == bytes)
            try FileManager.default.removeItem(at: target)
            #expect(throws: LibraryError.notRegularLibrary) { try LibraryStore(rootURL: root).load() }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        }
    }

    @Test func fifoAndDirectoryAreRejectedWithoutCreatingOrRemovingFiles() throws {
        try fixture { root in
            let file = root.appendingPathComponent("library.json")
            #expect(mkfifo(file.path, 0o600) == 0)
            #expect(throws: LibraryError.notRegularLibrary) { try LibraryStore(rootURL: root).load() }
            var info = stat()
            #expect(lstat(file.path, &info) == 0)
            #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: LibraryError.notRegularLibrary) { try LibraryStore(rootURL: root).load() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: file.path).isEmpty)
        }
    }

    @Test func sparseOversizeJSONIsRejectedBeforeReadingAndPreserved() throws {
        try fixture { root in
            let store = LibraryStore(rootURL: root)
            #expect(FileManager.default.createFile(atPath: store.stateURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: store.stateURL)
            defer { try? handle.close() }
            let size = UInt64(LibraryStateFile.maximumBytes + 1)
            try handle.truncate(atOffset: size)
            #expect(throws: LibraryError.libraryTooLarge) { try store.load() }
            #expect(try handle.seekToEnd() == size)
        }
    }

    @Test func oversizedSavePreservesPriorLibrary() throws {
        try fixture { root in
            let store = LibraryStore(rootURL: root)
            let original = LibraryState()
            try store.save(original)
            let bytes = try Data(contentsOf: store.stateURL)
            let huge = Wallpaper(title: String(repeating: "x", count: LibraryStateFile.maximumBytes), kind: .image, source: .local(filename: "photo.png"))
            #expect(throws: LibraryError.libraryTooLarge) { try store.save(LibraryState(wallpapers: [huge])) }
            #expect(try Data(contentsOf: store.stateURL) == bytes)
            #expect(try store.load() == original)
        }
    }
}
