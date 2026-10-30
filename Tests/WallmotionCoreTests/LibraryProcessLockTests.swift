import Foundation
import Darwin
import Testing
@testable import WallmotionCore

struct LibraryProcessLockTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test func exclusiveLeaseIsPrivateReleaseIsIdempotentAndInodePersists() throws {
        try fixture { root in
            #expect(chmod(root.path, 0o755) == 0)
            let first = try #require(try LibraryProcessLock.acquire(in: root))
            let path = root.appendingPathComponent(LibraryProcessLock.filename).path
            var before = stat(), after = stat(), directory = stat()
            #expect(lstat(path, &before) == 0)
            #expect(before.st_mode & 0o777 == 0o600)
            #expect(try LibraryProcessLock.acquire(in: root) == nil)
            first.release()
            first.release()
            let second = try #require(try LibraryProcessLock.acquire(in: root))
            defer { second.release() }
            #expect(lstat(path, &after) == 0)
            #expect(before.st_ino == after.st_ino)
            #expect(lstat(root.path, &directory) == 0)
            #expect(directory.st_mode & 0o777 == 0o755)
        }
    }

    @Test func deinitReleasesAndExistingRegularModeIsNormalized() throws {
        try fixture { root in
            let file = root.appendingPathComponent(LibraryProcessLock.filename)
            let bytes = Data("existing control file".utf8)
            try bytes.write(to: file)
            #expect(chmod(file.path, 0o644) == 0)
            func acquireAndDrop() throws {
                let lease = try #require(try LibraryProcessLock.acquire(in: root))
                try withExtendedLifetime(lease) {
                    let busy = try LibraryProcessLock.acquire(in: root)
                    #expect(busy == nil)
                }
            }
            try acquireAndDrop()
            let next = try #require(try LibraryProcessLock.acquire(in: root))
            defer { next.release() }
            var info = stat()
            #expect(lstat(file.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func symlinksHardlinksAndFIFOAreRejectedWithoutChangingTargets() throws {
        try fixture { root in
            let victim = root.appendingPathComponent("victim")
            let file = root.appendingPathComponent(LibraryProcessLock.filename)
            let bytes = Data("preserved".utf8)
            try bytes.write(to: victim)
            #expect(chmod(victim.path, 0o644) == 0)
            for target in [victim, root.appendingPathComponent("missing")] {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                #expect(throws: LibraryLockError.invalidFile) { try LibraryProcessLock.acquire(in: root) }
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
                try FileManager.default.removeItem(at: file)
            }
            #expect(link(victim.path, file.path) == 0)
            #expect(throws: LibraryLockError.invalidFile) { try LibraryProcessLock.acquire(in: root) }
            var info = stat()
            #expect(lstat(victim.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o644)
            #expect(try Data(contentsOf: victim) == bytes)
            try FileManager.default.removeItem(at: file)
            #expect(mkfifo(file.path, 0o600) == 0)
            #expect(throws: LibraryLockError.invalidFile) { try LibraryProcessLock.acquire(in: root) }
        }
    }

    private func python(_ script: String, root: URL) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, root.appendingPathComponent(LibraryProcessLock.filename).path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        return (process, pipe)
    }

    @Test func independentProcessCannotAcquireUntilSwiftLeaseReleases() throws {
        try fixture { root in
            let lease = try #require(try LibraryProcessLock.acquire(in: root))
            defer { lease.release() }
            let script = """
            import os,sys,fcntl,signal
            signal.alarm(5)
            fd=os.open(sys.argv[1],os.O_RDWR)
            try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: sys.exit(17)
            """
            let (busy, _) = try python(script, root: root)
            busy.waitUntilExit()
            #expect(busy.terminationStatus == 17)
            lease.release()
            let (available, _) = try python(script, root: root)
            available.waitUntilExit()
            #expect(available.terminationStatus == 0)
        }
    }

    @Test func killingIndependentHolderReleasesLockWithoutDeletingFile() throws {
        try fixture { root in
            let script = """
            import os,sys,fcntl,signal
            signal.alarm(5)
            fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600)
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            print('held',flush=True)
            signal.pause()
            """
            let (holder, output) = try python(script, root: root)
            defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
            #expect(output.fileHandleForReading.readData(ofLength: 5) == Data("held\n".utf8))
            #expect(try LibraryProcessLock.acquire(in: root) == nil)
            #expect(kill(holder.processIdentifier, SIGKILL) == 0)
            holder.waitUntilExit()
            let acquired = try #require(try LibraryProcessLock.acquire(in: root))
            acquired.release()
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryProcessLock.filename).path))
        }
    }
}
