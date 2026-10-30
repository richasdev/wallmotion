import AppKit
import WallmotionCore

@MainActor
struct InstanceWorkspace {
    enum Failure: Error { case ownerUnavailable, deliveryUnconfirmed }
    let rootURL: URL
    let bundleIdentifier: String

    private func owner() throws -> NSRunningApplication {
        guard let identity = try LibraryProcessIdentity.read(in: rootURL),
              identity.bundleIdentifier == bundleIdentifier,
              identity.processID != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: identity.processID),
              !application.isTerminated,
              identity.matches(processID: application.processIdentifier,
                               bundleIdentifier: application.bundleIdentifier,
                               launchTime: application.launchDate?.timeIntervalSince1970),
              application.bundleURL?.isFileURL == true else { throw Failure.ownerUnavailable }
        return application
    }

    private func configuration() -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        config.allowsRunningApplicationSubstitution = false
        config.addsToRecentItems = false
        config.activates = true
        return config
    }

    func activate() async throws {
        let app = try owner()
        guard let url = app.bundleURL else { throw Failure.ownerUnavailable }
        let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration()) { result, error in
                guard error == nil, let result else { continuation.resume(throwing: Failure.deliveryUnconfirmed); return }
                continuation.resume(returning: result.processIdentifier)
            }
        }
        try confirm(pid)
    }

    func forward(_ urls: [URL]) async throws {
        let app = try owner()
        guard let url = app.bundleURL else { throw Failure.ownerUnavailable }
        let pid: Int32 = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: configuration()) { result, error in
                guard error == nil, let result else { continuation.resume(throwing: Failure.deliveryUnconfirmed); return }
                continuation.resume(returning: result.processIdentifier)
            }
        }
        try confirm(pid)
    }

    private func confirm(_ pid: Int32) throws {
        guard try owner().processIdentifier == pid else { throw Failure.deliveryUnconfirmed }
    }
}
