import Foundation

public struct LibraryStore: Sendable {
    public let rootURL: URL
    public var mediaDirectory: URL { rootURL.appendingPathComponent("Media", isDirectory: true) }
    public var stateURL: URL { rootURL.appendingPathComponent("library.json") }

    public init(rootURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Wallmotion", isDirectory: true)) {
        self.rootURL = rootURL
    }

    public func load() throws -> LibraryState {
        guard let data = try LibraryStateFile.read(at: stateURL) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: data).validated()
    }

    public func save(_ state: LibraryState) throws {
        let state = try state.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try LibraryStateFile.write(data, at: stateURL)
    }

    public func importFile(at url: URL) throws -> Wallpaper {
        guard url.isFileURL else { throw LibraryError.notRegularFile }
        let kind = try MediaKind.classify(fileURL: url)
        let id = UUID()
        let filename = id.uuidString + "." + url.pathExtension.lowercased()
        try ManagedMediaFiles.copy(from: url, filename: filename, kind: kind, root: rootURL)
        return Wallpaper(id: id, title: url.deletingPathExtension().lastPathComponent, kind: kind, source: .local(filename: filename))
    }

    public func resolvedURL(for wallpaper: Wallpaper) throws -> URL {
        switch wallpaper.source {
        case .local(let filename):
            try Self.validateFilename(filename)
            try ManagedMediaFiles.validate(filename: filename, root: rootURL)
            return mediaDirectory.appendingPathComponent(filename)
        case .web(let embed):
            try embed.validate()
            return embed.pageURL
        case .remote(let url): return try MediaURL.validatePersisted(url.absoluteString)
        }
    }

    public func deleteMedia(for wallpaper: Wallpaper) throws {
        guard case .local(let filename) = wallpaper.source else { return }
        try Self.validateFilename(filename)
        try ManagedMediaFiles.remove(filename: filename, root: rootURL)
    }

    public static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
            throw LibraryError.invalidLocalPath
        }
    }
}
