import Foundation

public struct LibraryStore: Sendable {
    public let rootURL: URL
    public var mediaDirectory: URL { rootURL.appendingPathComponent("Media", isDirectory: true) }
    public var stateURL: URL { rootURL.appendingPathComponent("library.json") }

    public init(rootURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Wallmotion", isDirectory: true)) {
        self.rootURL = rootURL
    }

    public func load() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: stateURL)).validated()
    }

    public func save(_ state: LibraryState) throws {
        _ = try state.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    public func importFile(at url: URL) throws -> Wallpaper {
        guard url.isFileURL else { throw LibraryError.notRegularFile }
        let kind = try MediaKind.classify(fileURL: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryError.notRegularFile }
        if kind == .gif { _ = try GIFPreflight.inspect(url: url) }
        let id = UUID()
        let filename = id.uuidString + "." + url.pathExtension.lowercased()
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: mediaDirectory.appendingPathComponent(filename))
        return Wallpaper(id: id, title: url.deletingPathExtension().lastPathComponent, kind: kind, source: .local(filename: filename))
    }

    public func resolvedURL(for wallpaper: Wallpaper) throws -> URL {
        switch wallpaper.source {
        case .local(let filename):
            try Self.validateFilename(filename)
            return mediaDirectory.appendingPathComponent(filename)
        case .remote(let url): return try MediaURL.validate(url.absoluteString)
        }
    }

    public func deleteMedia(for wallpaper: Wallpaper) throws {
        guard case .local = wallpaper.source else { return }
        let url = try resolvedURL(for: wallpaper)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public static func validateFilename(_ filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
            throw LibraryError.invalidLocalPath
        }
    }
}
