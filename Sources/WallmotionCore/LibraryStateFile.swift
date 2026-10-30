import Foundation
import Darwin

/// Bounds input bytes, not the decoder's allocations or total process memory.
/// The descriptor pins the opened file; O_NOFOLLOW rejects a leaf symlink and
/// O_NONBLOCK lets us reject a FIFO without waiting for a writer.
enum LibraryStateFile {
    static let maximumBytes = 16 * 1024 * 1024

    static func read(at url: URL, maximumBytes: Int = maximumBytes) throws -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw LibraryError.invalidState }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw LibraryError.notRegularLibrary }
            throw posixError()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LibraryError.notRegularLibrary }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw LibraryError.libraryTooLarge }
        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Read one byte past the remaining allowance to detect growth after
            // fstat. Never retain that extra byte or trust size metadata alone.
            let count = min(buffer.count, maximumBytes - data.count + 1)
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if result == 0 { return data }
            guard result <= maximumBytes - data.count else { throw LibraryError.libraryTooLarge }
            data.append(contentsOf: buffer.prefix(result))
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
