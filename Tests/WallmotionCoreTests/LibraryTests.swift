import Foundation
import Testing
@testable import WallmotionCore

@Suite("Library state")
struct LibraryStateTests {
    @Test func removalClearsOnlyAssignmentsForRemovedWallpaper() throws {
        let first = try Wallpaper.remote("https://cdn.example.com/first.mp4")
        let second = try Wallpaper.remote("https://cdn.example.com/second.mp4")
        var state = LibraryState(wallpapers: [first, second], assignments: [
            "display-1": first.id, "display-2": first.id, "display-3": second.id
        ])
        state.remove(id: first.id)
        #expect(state.wallpapers == [second])
        #expect(state.assignments == ["display-3": second.id])
        #expect(try state.validated() == state)
    }

    @Test func removingUnknownIDPreservesState() throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        var state = LibraryState(wallpapers: [item], assignments: ["display-1": item.id])
        let original = state
        state.remove(id: UUID())
        #expect(state == original)
    }

    @Test func rejectsDuplicateIDsAndDanglingOrEmptyDisplayAssignments() throws {
        let item = try Wallpaper.remote("https://cdn.example.com/video.mp4")
        let invalidStates = [
            LibraryState(wallpapers: [item, item]),
            LibraryState(wallpapers: [item], assignments: ["display-1": UUID()]),
            LibraryState(wallpapers: [item], assignments: ["": item.id])
        ]
        for state in invalidStates {
            #expect(throws: LibraryError.invalidState) { try state.validated() }
        }
    }

    @Test func rejectsNonVideoRemoteWallpaper() {
        let item = Wallpaper(title: "Invalid", kind: .image, source: .remote(url: URL(string: "https://cdn.example.com/video.mp4")!))
        #expect(throws: LibraryError.invalidState) { try LibraryState(wallpapers: [item]).validated() }
    }
}

@Suite("Library persistence and imports")
struct LibraryStoreTests {
    private func withTemporaryStore(_ body: (LibraryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LibraryStore(rootURL: directory.appendingPathComponent("Library", isDirectory: true)), directory)
    }

    @Test func missingLibraryLoadsDefaultsWithoutCreatingFiles() throws {
        try withTemporaryStore { store, _ in
            let loaded = try store.load()
            #expect(loaded == LibraryState())
            #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
        }
    }

    @Test func roundTripPreservesMediaDisplaysAndPlaybackSettings() throws {
        try withTemporaryStore { store, _ in
            let local = Wallpaper(title: "Praia 日本語", kind: .gif, source: .local(filename: "animation.gif"), addedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let remote = try Wallpaper.remote("https://cdn.example.com/stream?token=a%2Fb")
            let original = LibraryState(wallpapers: [local, remote], assignments: ["display-1": local.id, "display-2": remote.id], settings: .init(pauseOnLowPower: false, isManuallyPaused: true))
            try store.save(original)
            #expect(try store.load() == original)
            var replacement = original
            replacement.remove(id: local.id)
            try store.save(replacement)
            #expect(try store.load() == replacement)
            let contents = try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
            #expect(contents == ["library.json"])
        }
    }

    @Test func invalidSavePreservesPreviousLibraryBytes() throws {
        try withTemporaryStore { store, _ in
            try store.save(LibraryState())
            let originalBytes = try Data(contentsOf: store.stateURL)
            #expect(throws: LibraryError.unsupportedVersion) { try store.save(LibraryState(version: 999)) }
            #expect(throws: LibraryError.invalidState) { try store.save(LibraryState(assignments: ["display": UUID()])) }
            #expect(try Data(contentsOf: store.stateURL) == originalBytes)
        }
    }

    @Test func corruptOrFutureLibraryLoadDoesNotOverwriteData() throws {
        try withTemporaryStore { store, _ in
            try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true)
            let corrupt = Data("{not valid JSON".utf8)
            try corrupt.write(to: store.stateURL)
            #expect(throws: (any Error).self) { try store.load() }
            #expect(try Data(contentsOf: store.stateURL) == corrupt)
            let future = try JSONEncoder().encode(LibraryState(version: 999))
            try future.write(to: store.stateURL)
            #expect(throws: LibraryError.unsupportedVersion) { try store.load() }
            #expect(try Data(contentsOf: store.stateURL) == future)
        }
    }

    @Test func importsCopiesWithUniqueUUIDNamesAndPreservesOriginal() throws {
        try withTemporaryStore { store, directory in
            let source = directory.appendingPathComponent("Pôr do sol.MP4")
            let bytes = Data([0, 1, 2, 3, 255])
            try bytes.write(to: source)
            let first = try store.importFile(at: source)
            let second = try store.importFile(at: source)
            #expect(first.id != second.id)
            #expect(first.title == "Pôr do sol")
            #expect(first.kind == .video)
            #expect(first.source == .local(filename: first.id.uuidString + ".mp4"))
            #expect(second.source == .local(filename: second.id.uuidString + ".mp4"))
            #expect(try Data(contentsOf: store.resolvedURL(for: first)) == bytes)
            #expect(try Data(contentsOf: store.resolvedURL(for: second)) == bytes)
            try store.deleteMedia(for: first)
            #expect(!FileManager.default.fileExists(atPath: try store.resolvedURL(for: first).path))
            #expect(try Data(contentsOf: source) == bytes)
            #expect(try Data(contentsOf: store.resolvedURL(for: second)) == bytes)
        }
    }

    @Test func rejectsDirectoriesSymlinksAndRemoteImports() throws {
        try withTemporaryStore { store, directory in
            let folder = directory.appendingPathComponent("folder.mp4", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(throws: LibraryError.notRegularFile) { try store.importFile(at: folder) }
            let source = directory.appendingPathComponent("source.gif")
            try Data([1, 2]).write(to: source)
            let symlink = directory.appendingPathComponent("link.gif")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
            #expect(throws: LibraryError.notRegularFile) { try store.importFile(at: symlink) }
            #expect(throws: LibraryError.notRegularFile) { try store.importFile(at: URL(string: "https://cdn.example.com/video.mp4")!) }
            #expect(!FileManager.default.fileExists(atPath: store.mediaDirectory.path))
        }
    }

    @Test(arguments: ["", ".", "..", "../outside.mp4", "/tmp/outside.mp4", "nested/video.mp4", "nested\\video.mp4", "video\0.mp4"])
    func rejectsTraversalAndInvalidLocalReferences(_ filename: String) throws {
        try withTemporaryStore { store, _ in
            let item = Wallpaper(title: "Unsafe", kind: .video, source: .local(filename: filename))
            #expect(throws: LibraryError.invalidLocalPath) { try store.resolvedURL(for: item) }
            #expect(throws: LibraryError.invalidLocalPath) { try store.deleteMedia(for: item) }
            #expect(throws: LibraryError.invalidLocalPath) { try store.save(LibraryState(wallpapers: [item])) }
        }
    }

    @Test func remoteDeletionDoesNotTouchLocalMediaOrState() throws {
        try withTemporaryStore { store, directory in
            let source = directory.appendingPathComponent("local.mp4")
            let bytes = Data([9, 8, 7])
            try bytes.write(to: source)
            let local = try store.importFile(at: source)
            let remote = try Wallpaper.remote("https://cdn.example.com/local.mp4")
            let state = LibraryState(wallpapers: [local, remote])
            try store.save(state)
            try store.deleteMedia(for: remote)
            #expect(try Data(contentsOf: store.resolvedURL(for: local)) == bytes)
            #expect(try store.load() == state)
            #expect(try store.resolvedURL(for: remote) == URL(string: "https://cdn.example.com/local.mp4"))
        }
    }
}
