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
    // Display UUID → wallpaper UUID → proportional presentation mode.
    public var mediaFits: [String: [String: MediaFit]]

    public init(version: Int = 2, wallpapers: [Wallpaper] = [], assignments: [String: UUID] = [:], settings: PlaybackSettings = .init(), mediaFits: [String: [String: MediaFit]] = [:]) {
        self.version = version
        self.wallpapers = wallpapers
        self.assignments = assignments
        self.settings = settings
        self.mediaFits = mediaFits
    }

    private enum CodingKeys: String, CodingKey {
        case version, wallpapers, assignments, settings, mediaFits
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        wallpapers = try values.decode([Wallpaper].self, forKey: .wallpapers)
        assignments = try values.decode([String: UUID].self, forKey: .assignments)
        settings = try values.decode(PlaybackSettings.self, forKey: .settings)
        mediaFits = try values.decodeIfPresent([String: [String: MediaFit]].self, forKey: .mediaFits) ?? [:]
    }

    public func mediaFit(for wallpaperID: UUID, on displayID: String) -> MediaFit {
        mediaFits[displayID]?[wallpaperID.uuidString] ?? .fit
    }

    public mutating func setMediaFit(_ fit: MediaFit, for wallpaperID: UUID, on displayID: String) {
        mediaFits[displayID, default: [:]][wallpaperID.uuidString] = fit
    }

    public mutating func remove(id: UUID) {
        wallpapers.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        for display in Array(mediaFits.keys) {
            mediaFits[display]?.removeValue(forKey: id.uuidString)
            if mediaFits[display]?.isEmpty == true { mediaFits.removeValue(forKey: display) }
        }
    }

    public func validated() throws -> LibraryState {
        guard version == 1 || version == 2 else { throw LibraryError.unsupportedVersion }
        let ids = Set(wallpapers.map(\.id))
        guard ids.count == wallpapers.count,
              assignments.allSatisfy({ !$0.key.isEmpty && ids.contains($0.value) }) else { throw LibraryError.invalidState }
        let fitIDs = Set(wallpapers.map { $0.id.uuidString })
        guard mediaFits.allSatisfy({ display, fits in
            !display.isEmpty && fits.keys.allSatisfy { fitIDs.contains($0) }
        }) else { throw LibraryError.invalidState }
        for item in wallpapers {
            switch item.source {
            case .web(let embed):
                guard version == 2, item.kind == .video else { throw LibraryError.invalidState }
                try embed.validate()
            case .local(let filename): try LibraryStore.validateFilename(filename)
            case .remote(let url):
                _ = try MediaURL.validatePersisted(url.absoluteString)
                guard item.kind == .video else { throw LibraryError.invalidState }
            }
        }
        var migrated = self
        migrated.version = 2
        return migrated
    }
}
