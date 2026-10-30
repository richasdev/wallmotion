import Foundation

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public var pauseOnLowPower: Bool
    public var isManuallyPaused: Bool

    public init(pauseOnLowPower: Bool = true, isManuallyPaused: Bool = false) {
        self.pauseOnLowPower = pauseOnLowPower
        self.isManuallyPaused = isManuallyPaused
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var version: Int
    public var wallpapers: [Wallpaper]
    public var assignments: [String: UUID]
    public var settings: PlaybackSettings

    public init(version: Int = 2, wallpapers: [Wallpaper] = [], assignments: [String: UUID] = [:], settings: PlaybackSettings = .init()) {
        self.version = version
        self.wallpapers = wallpapers
        self.assignments = assignments
        self.settings = settings
    }

    public mutating func remove(id: UUID) {
        wallpapers.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }

    public func validated() throws -> LibraryState {
        guard version == 1 || version == 2 else { throw LibraryError.unsupportedVersion }
        let ids = Set(wallpapers.map(\.id))
        guard ids.count == wallpapers.count,
              assignments.allSatisfy({ !$0.key.isEmpty && ids.contains($0.value) }) else { throw LibraryError.invalidState }
        for item in wallpapers {
            switch item.source {
            case .web(let embed):
                guard version == 2, item.kind == .video else { throw LibraryError.invalidState }
                try embed.validate()
            case .local(let filename): try LibraryStore.validateFilename(filename)
            case .remote(let url):
                _ = try MediaURL.validate(url.absoluteString)
                guard item.kind == .video else { throw LibraryError.invalidState }
            }
        }
        var migrated = self
        migrated.version = 2
        return migrated
    }
}
