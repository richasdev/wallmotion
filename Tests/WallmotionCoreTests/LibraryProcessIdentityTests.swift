import Foundation
import Darwin
import Testing
@testable import WallmotionCore

struct LibraryProcessIdentityTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func publicationIsPrivateAndRequiresAHeldLease() throws {
        try fixture { root in
            let identity = LibraryProcessIdentity(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12345)
            let lease = try #require(try LibraryProcessLock.acquire(in: root))
            defer { lease.release() }
            try lease.publishIdentity(identity)
            #expect(try LibraryProcessIdentity.read(in: root) == identity)
            var info = stat()
            #expect(lstat(root.appendingPathComponent(LibraryProcessIdentity.filename).path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            lease.release()
            #expect(throws: LibraryLockError.notHeld) { try lease.publishIdentity(identity) }
        }
    }

    @Test func identityRequiresPidBundleAndAvailableLaunchTimeToMatch() {
        let identity = LibraryProcessIdentity(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12345)
        #expect(identity.matches(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12345))
        #expect(!identity.matches(processID: 124, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12345))
        #expect(!identity.matches(processID: 123, bundleIdentifier: "other.app", launchTime: 12345))
        #expect(!identity.matches(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12346))
        #expect(!identity.matches(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: nil))
        #expect(!identity.matches(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: .nan))
    }

    @Test func invalidAndOversizedDiscoveryFilesFailClosedWithoutFollowingLinks() throws {
        try fixture { root in
            let path = root.appendingPathComponent(LibraryProcessIdentity.filename)
            #expect(try LibraryProcessIdentity.read(in: root) == nil)
            try Data(repeating: 65, count: 1025).write(to: path)
            #expect(throws: LibraryError.libraryTooLarge) { try LibraryProcessIdentity.read(in: root) }
            try FileManager.default.removeItem(at: path)
            let victim = root.appendingPathComponent("outside")
            let bytes = Data("preserved".utf8)
            try bytes.write(to: victim)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
            #expect(throws: LibraryError.notRegularLibrary) { try LibraryProcessIdentity.read(in: root) }
            let lease = try #require(try LibraryProcessLock.acquire(in: root))
            defer { lease.release() }
            #expect(throws: LibraryError.notRegularLibrary) { try lease.publishIdentity(.init(processID: 123, bundleIdentifier: "dev.richas.wallmotion", launchTime: 12345)) }
            #expect(try Data(contentsOf: victim) == bytes)
            #expect(throws: LibraryError.invalidState) { try lease.publishIdentity(.init(processID: -1, bundleIdentifier: "bad\nidentifier", launchTime: 12345)) }
        }
    }
}
