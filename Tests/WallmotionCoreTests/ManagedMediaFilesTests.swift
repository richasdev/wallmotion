import Foundation
import Darwin
import Testing
@testable import WallmotionCore

@Suite("Managed media containment")
struct ManagedMediaFilesTests {
    private func fixture(_ body: (LibraryStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionPrivateMedia-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(LibraryStore(rootURL: root.appendingPathComponent("Library")), root)
    }

    @Test func importCreatesPrivateCopyPreservingBytesOriginalAndQuarantine() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("source.mp4")
            let bytes = Data([1, 2, 3, 4])
            try bytes.write(to: source)
            #expect(chmod(source.path, 0o777) == 0)
            let quarantine = Array("0081;00000000;WallmotionTests;".utf8)
            let result = quarantine.withUnsafeBytes { setxattr(source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            #expect(result == 0)
            let item = try store.importFile(at: source)
            let destination = try store.resolvedURL(for: item)
            let copied = try FileManager.default.attributesOfItem(atPath: destination.path)
            let original = try FileManager.default.attributesOfItem(atPath: source.path)
            #expect((copied[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((original[.posixPermissions] as? NSNumber)?.intValue == 0o777)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(try Data(contentsOf: source) == bytes)
            var value = [UInt8](repeating: 0, count: 256)
            let count = value.withUnsafeMutableBytes { getxattr(destination.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }
            // libcopyfile normalizes quarantine timestamp/agent fields. Preserve
            // the marker and flags rather than asserting byte-identical metadata.
            #expect(count > 0)
            #expect(String(decoding: value.prefix(max(0, count)), as: UTF8.self).hasPrefix("0081;"))
            let directory = try FileManager.default.attributesOfItem(atPath: store.mediaDirectory.path)
            #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }

    @Test func mediaDirectorySymlinkRejectsCopyResolveAndDeleteWithoutTouchingOutside() throws {
        try fixture { store, root in
            let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: store.rootURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: store.mediaDirectory, withDestinationURL: outside)
            let victim = outside.appendingPathComponent("victim.mp4")
            let bytes = Data([4, 5, 6])
            try bytes.write(to: victim)
            let item = Wallpaper(title: "Victim", kind: .video, source: .local(filename: "victim.mp4"))
            #expect(throws: LibraryError.invalidLocalPath) { try store.importFile(at: victim) }
            #expect(throws: LibraryError.invalidLocalPath) { try store.resolvedURL(for: item) }
            #expect(throws: LibraryError.invalidLocalPath) { try store.deleteMedia(for: item) }
            #expect(try Data(contentsOf: victim) == bytes)
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["victim.mp4"])
            let remote = try Wallpaper.remote("https://example.com/video.mp4")
            #expect(try store.resolvedURL(for: remote).host == "example.com")
            try store.deleteMedia(for: remote)
        }
    }

    @Test func leafSymlinkIncludingDanglingLinkRejectsResolveAndDelete() throws {
        try fixture { store, root in
            try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside.mp4")
            let bytes = Data([7, 8, 9])
            try bytes.write(to: outside)
            let link = store.mediaDirectory.appendingPathComponent("link.mp4")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            let item = Wallpaper(title: "Link", kind: .video, source: .local(filename: "link.mp4"))
            for exists in [true, false] {
                if !exists { try FileManager.default.removeItem(at: outside) }
                #expect(throws: LibraryError.notRegularFile) { try store.resolvedURL(for: item) }
                #expect(throws: LibraryError.notRegularFile) { try store.deleteMedia(for: item) }
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
                if exists { #expect(try Data(contentsOf: outside) == bytes) }
            }
        }
    }

    @Test func sourceFIFOAndManagedFIFOAreRejectedWithoutBlocking() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("fifo.mp4")
            #expect(mkfifo(source.path, 0o600) == 0)
            #expect(throws: LibraryError.notRegularFile) { try store.importFile(at: source) }
            #expect(!FileManager.default.fileExists(atPath: store.mediaDirectory.path))
            try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
            let leaf = store.mediaDirectory.appendingPathComponent("fifo.mp4")
            #expect(mkfifo(leaf.path, 0o600) == 0)
            let item = Wallpaper(title: "FIFO", kind: .video, source: .local(filename: "fifo.mp4"))
            #expect(throws: LibraryError.notRegularFile) { try store.resolvedURL(for: item) }
            #expect(throws: LibraryError.notRegularFile) { try store.deleteMedia(for: item) }
        }
    }

    @Test func invalidGIFNeverPublishesCopy() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("bad.gif")
            try Data([1, 2, 3]).write(to: source)
            #expect(throws: LibraryError.invalidGIF) { try store.importFile(at: source) }
            #expect(!FileManager.default.fileExists(atPath: store.mediaDirectory.path))
        }
    }
}
