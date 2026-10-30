import Foundation

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public var pauseOnMemoryPressure: Bool
    public var pauseOnThermalPressure: Bool
    public var pauseOnLowPower: Bool
    public var isManuallyPaused: Bool
    public var audioDisplayID: String?
    public var hlsResolution: HLSResolution
    public var audioVolume: Double

    public init(pauseOnLowPower: Bool = true, isManuallyPaused: Bool = false, audioDisplayID: String? = nil, audioVolume: Double = 1, pauseOnThermalPressure: Bool = true, hlsResolution: HLSResolution = .automatic, pauseOnMemoryPressure: Bool = true) {
        self.pauseOnMemoryPressure = pauseOnMemoryPressure
        self.hlsResolution = hlsResolution
        self.pauseOnThermalPressure = pauseOnThermalPressure
        self.pauseOnLowPower = pauseOnLowPower
        self.isManuallyPaused = isManuallyPaused
        self.audioDisplayID = audioDisplayID
        self.audioVolume = audioVolume
    }

    private enum CodingKeys: String, CodingKey {
        case pauseOnLowPower, isManuallyPaused, audioDisplayID, audioVolume, pauseOnThermalPressure, hlsResolution, pauseOnMemoryPressure
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnMemoryPressure = try values.decodeIfPresent(Bool.self, forKey: .pauseOnMemoryPressure) ?? true
        hlsResolution = try values.decodeIfPresent(HLSResolution.self, forKey: .hlsResolution) ?? .automatic
        pauseOnThermalPressure = try values.decodeIfPresent(Bool.self, forKey: .pauseOnThermalPressure) ?? true
        pauseOnLowPower = try values.decodeIfPresent(Bool.self, forKey: .pauseOnLowPower) ?? true
        isManuallyPaused = try values.decodeIfPresent(Bool.self, forKey: .isManuallyPaused) ?? false
        audioDisplayID = try values.decodeIfPresent(String.self, forKey: .audioDisplayID)
        audioVolume = try values.decodeIfPresent(Double.self, forKey: .audioVolume) ?? 1
    }
}

public struct LibraryState: Codable, Equatable, Sendable {
    public var version: Int
    public var wallpapers: [Wallpaper]
    public var assignments: [String: UUID]
    public var displayMode: DisplayMode
    public var mirroredWallpaperID: UUID?
    public var mirroredMediaFit: MediaFit
    public var settings: PlaybackSettings
    // Display UUID → wallpaper UUID → proportional presentation mode.
    public var mediaFits: [String: [String: MediaFit]]

    public init(version: Int = 4, wallpapers: [Wallpaper] = [], assignments: [String: UUID] = [:], settings: PlaybackSettings = .init(), mediaFits: [String: [String: MediaFit]] = [:], displayMode: DisplayMode = .independent, mirroredWallpaperID: UUID? = nil, mirroredMediaFit: MediaFit = .fit) {
        self.version = version
        self.wallpapers = wallpapers
        self.assignments = assignments
        self.settings = settings
        self.mediaFits = mediaFits
        self.displayMode = displayMode
        self.mirroredWallpaperID = mirroredWallpaperID
        self.mirroredMediaFit = mirroredMediaFit
    }

    private enum CodingKeys: String, CodingKey {
        case version, wallpapers, assignments, settings, mediaFits, displayMode, mirroredWallpaperID, mirroredMediaFit
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        wallpapers = try values.decode([Wallpaper].self, forKey: .wallpapers)
        assignments = try values.decode([String: UUID].self, forKey: .assignments)
        settings = try values.decodeIfPresent(PlaybackSettings.self, forKey: .settings) ?? .init()
        displayMode = try values.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .independent
        mirroredWallpaperID = try values.decodeIfPresent(UUID.self, forKey: .mirroredWallpaperID)
        mirroredMediaFit = try values.decodeIfPresent(MediaFit.self, forKey: .mirroredMediaFit) ?? .fit
        mediaFits = try values.decodeIfPresent([String: [String: MediaFit]].self, forKey: .mediaFits) ?? [:]
    }

    public func effectiveAssignments(for displayIDs: [String]) -> [String: UUID] {
        switch displayMode {
        case .independent:
            let connected = Set(displayIDs)
            return assignments.filter { connected.contains($0.key) }
        case .mirrored, .spanned:
            guard let mirroredWallpaperID else { return [:] }
            return Dictionary(displayIDs.map { ($0, mirroredWallpaperID) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func mediaFit(for wallpaperID: UUID, on displayID: String) -> MediaFit {
        displayMode.isShared ? mirroredMediaFit : mediaFits[displayID]?[wallpaperID.uuidString] ?? .fit
    }

    public mutating func setMediaFit(_ fit: MediaFit, for wallpaperID: UUID, on displayID: String) {
        if displayMode.isShared { mirroredMediaFit = fit }
        else { mediaFits[displayID, default: [:]][wallpaperID.uuidString] = fit }
    }

    public mutating func remove(id: UUID) {
        wallpapers.removeAll { $0.id == id }
        if mirroredWallpaperID == id { mirroredWallpaperID = nil }
        assignments = assignments.filter { $0.value != id }
        for display in Array(mediaFits.keys) {
            mediaFits[display]?.removeValue(forKey: id.uuidString)
            if mediaFits[display]?.isEmpty == true { mediaFits.removeValue(forKey: display) }
        }
    }

    public func validated() throws -> LibraryState {
        guard (1...4).contains(version) else { throw LibraryError.unsupportedVersion }
        let ids = Set(wallpapers.map(\.id))
        guard ids.count == wallpapers.count,
              mirroredWallpaperID.map(ids.contains) != false,
              settings.audioDisplayID?.isEmpty != true,
              settings.audioVolume.isFinite, (0...1).contains(settings.audioVolume),
              assignments.allSatisfy({ !$0.key.isEmpty && ids.contains($0.value) }) else { throw LibraryError.invalidState }
        if displayMode == .spanned, let mirroredWallpaperID,
           let item = wallpapers.first(where: { $0.id == mirroredWallpaperID }) {
            guard item.supportsPanorama else { throw LibraryError.invalidState }
        }
        let fitIDs = Set(wallpapers.map { $0.id.uuidString })
        guard mediaFits.allSatisfy({ display, fits in
            !display.isEmpty && fits.keys.allSatisfy { fitIDs.contains($0) }
        }) else { throw LibraryError.invalidState }
        for item in wallpapers {
            switch item.source {
            case .web(let embed):
                guard version >= 2, item.kind == .video else { throw LibraryError.invalidState }
                try embed.validate()
            case .local(let filename): try LibraryStore.validateFilename(filename)
            case .remote(let url):
                _ = try MediaURL.validatePersisted(url.absoluteString)
                guard item.kind == .video else { throw LibraryError.invalidState }
            }
        }
        var migrated = self
        migrated.version = 4
        return migrated
    }
}
