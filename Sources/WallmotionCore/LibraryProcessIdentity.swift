import Foundation

/// Discovery hint for cooperating instances, not authentication against this UID.
public struct LibraryProcessIdentity: Codable, Equatable, Sendable {
    public static let filename = "wallmotion-owner.json"
    public let version: Int
    public let processID: Int32
    public let bundleIdentifier: String
    public let launchTime: Double?

    public init(processID: Int32, bundleIdentifier: String, launchTime: Double?) {
        version = 1
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.launchTime = launchTime
    }

    func validated() throws {
        guard version == 1, processID > 0, !bundleIdentifier.isEmpty,
              bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              launchTime.map({ $0.isFinite }) != false else { throw LibraryError.invalidState }
    }

    public static func read(in root: URL) throws -> Self? {
        guard root.isFileURL, [nil, "", "localhost"].contains(root.host) else { throw LibraryError.invalidLocalPath }
        guard let data = try LibraryStateFile.read(at: root.appendingPathComponent(filename), maximumBytes: 1024) else { return nil }
        let identity = try JSONDecoder().decode(Self.self, from: data)
        try identity.validated()
        return identity
    }

    /// PID plus launch time rejects ordinary PID reuse; the application must
    /// additionally verify the OS app bundle identity, liveness and bundle URL.
    public func matches(processID: Int32, bundleIdentifier: String?, launchTime: Double?) -> Bool {
        guard version == 1, self.processID > 0, self.processID == processID, self.bundleIdentifier == bundleIdentifier,
              let expected = self.launchTime, let actual = launchTime,
              expected.isFinite, actual.isFinite else { return false }
        return abs(expected - actual) < 0.001
    }
}
