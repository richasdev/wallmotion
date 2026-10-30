import OSLog

/// Scalar startup diagnostics only. Never log URLs, paths, filenames or OS errors.
enum InstanceDiagnostics {
    static let log = Logger(subsystem: "dev.richas.wallmotion", category: "instance")
}
