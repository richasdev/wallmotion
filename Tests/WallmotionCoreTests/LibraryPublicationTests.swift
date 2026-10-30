import Foundation
import Darwin
import Testing
@testable import WallmotionCore

struct LibraryPublicationTests {
    @Test func saveReplacesReadableLegacyFileWithOwnerOnlyMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try Data("legacy".utf8).write(to: store.stateURL)
        #expect(chmod(store.stateURL.path, 0o644) == 0)
        try store.save(LibraryState())
        var info = stat()
        #expect(lstat(store.stateURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try store.load() == LibraryState())
    }
    @Test func firstPublicationAndReplacementLeaveNoTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try store.save(LibraryState())
        let next = LibraryState(settings: .init(isManuallyPaused: true))
        try store.save(next)
        #expect(try store.load() == next)
        var info = stat()
        #expect(lstat(store.stateURL.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.json"])
    }

    @Test func nonRegularDestinationsArePreservedWithoutFollowingThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let outside = root.appendingPathComponent("outside.json")
        let original = Data("preserve me".utf8)
        try original.write(to: outside)
        for target in [outside, root.appendingPathComponent("missing.json")] {
            try FileManager.default.createSymbolicLink(at: store.stateURL, withDestinationURL: target)
            #expect(throws: LibraryError.notRegularLibrary) { try store.save(LibraryState()) }
            var info = stat()
            #expect(lstat(store.stateURL.path, &info) == 0)
            #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
            #expect(try Data(contentsOf: outside) == original)
            try FileManager.default.removeItem(at: store.stateURL)
        }
        #expect(mkfifo(store.stateURL.path, 0o600) == 0)
        #expect(throws: LibraryError.notRegularLibrary) { try store.save(LibraryState()) }
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        #expect(throws: LibraryError.notRegularLibrary) { try store.save(LibraryState()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["library.json", "outside.json"])
    }

    @Test func rejectedPayloadLeavesOriginalAndNoTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        try store.save(LibraryState())
        let original = try Data(contentsOf: store.stateURL)
        let oversized = Data(repeating: 0, count: LibraryStateFile.maximumBytes + 1)
        #expect(throws: LibraryError.libraryTooLarge) { try LibraryStateFile.write(oversized, at: store.stateURL) }
        #expect(try Data(contentsOf: store.stateURL) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.json"])
    }
}
