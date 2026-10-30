import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case image, gif, video

    public static func classify(fileURL: URL) throws -> MediaKind {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp": .image
        case "gif": .gif
        case "mp4", "mov", "m4v": .video
        default: throw LibraryError.unsupportedFile
        }
    }
}

public enum MediaSource: Codable, Equatable, Sendable {
    case local(filename: String)
    case remote(url: URL)
}

public struct Wallpaper: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: MediaKind
    public var source: MediaSource
    public var addedAt: Date

    public init(id: UUID = UUID(), title: String, kind: MediaKind, source: MediaSource, addedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.kind = kind
        self.source = source
        self.addedAt = addedAt
    }

    public static func remote(_ text: String) throws -> Wallpaper {
        let url = try MediaURL.validate(text)
        let last = url.lastPathComponent
        let title = (last.isEmpty || last == "/") ? (url.host ?? "Vídeo remoto") : last
        return Wallpaper(title: title, kind: .video, source: .remote(url: url))
    }
}

public enum MediaURL {
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { throw LibraryError.invalidURL }
        let pageHosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com", "twitch.tv"]
        let normalizedHost = host.lowercased()
        guard !pageHosts.contains(where: { normalizedHost == $0 || normalizedHost.hasSuffix("." + $0) }),
              !["html", "htm", "php", "asp", "aspx"].contains(url.pathExtension.lowercased()) else {
            throw LibraryError.webPageURL
        }
        return url
    }
}

public enum LibraryError: LocalizedError, Equatable {
    case unsupportedFile, invalidURL, webPageURL, invalidLocalPath, notRegularFile, unsupportedVersion, invalidState, invalidGIF, gifTooLarge

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Formato não suportado. Use uma foto, GIF ou vídeo MP4, MOV ou M4V."
        case .invalidURL: "Informe uma URL HTTPS válida, sem espaços ou credenciais."
        case .webPageURL: "Use o link direto do vídeo ou stream HLS. Páginas como YouTube ainda não são suportadas."
        case .invalidLocalPath: "A referência do arquivo na biblioteca é inválida."
        case .notRegularFile: "Selecione um arquivo de mídia comum."
        case .unsupportedVersion: "Esta biblioteca foi criada por uma versão incompatível do Wallmotion."
        case .invalidState: "A biblioteca contém seleções ou identificadores inválidos."
        case .invalidGIF: "O arquivo GIF está incompleto ou tem uma estrutura inválida."
        case .gifTooLarge: "Este GIF ultrapassa o orçamento estimado de 256 MiB de frames. Converta a animação para MP4 ou reduza a resolução."
        }
    }
}
