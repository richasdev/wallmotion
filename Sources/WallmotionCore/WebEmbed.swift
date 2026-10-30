import Foundation

/// A single official provider embed. Never a stream URL or arbitrary web page.
public struct WebEmbed: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case youtube, vimeo }
    public let provider: Provider
    public let videoID: String
    public let privacyHash: String?

    public init(provider: Provider, videoID: String, privacyHash: String? = nil) throws {
        self.provider = provider
        self.videoID = videoID
        self.privacyHash = privacyHash
        try validate()
    }

    public func validate() throws {
        let asciiID = videoID.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        switch provider {
        case .youtube:
            guard videoID.count == 11, asciiID, privacyHash == nil else { throw LibraryError.unsupportedEmbed }
        case .vimeo:
            guard (1...20).contains(videoID.count), videoID.utf8.allSatisfy({ (48...57).contains($0) }), videoID.first != "0" else { throw LibraryError.unsupportedEmbed }
            if let privacyHash {
                guard (1...64).contains(privacyHash.count), privacyHash.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { throw LibraryError.unsupportedEmbed }
            }
        }
    }

    public static func parse(_ text: String) throws -> WebEmbed {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace }), let c = URLComponents(string: text),
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, let host = c.host?.lowercased() else { throw LibraryError.unsupportedEmbed }
        let parts = c.path.split(separator: "/").map(String.init)
        let query = c.queryItems ?? []
        func single(_ name: String) throws -> String? {
            let values = query.filter { $0.name == name }
            guard values.count <= 1 else { throw LibraryError.unsupportedEmbed }
            return values.first?.value
        }
        let youtubeHosts = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]
        if host == "youtu.be" || youtubeHosts.contains(host) {
            let id: String?
            if host == "youtu.be", parts.count == 1 { id = parts[0] }
            else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host), parts == ["watch"] { id = try single("v") }
            else if youtubeHosts.contains(host), parts.count == 2,
                    (parts[0] == "embed" || (["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) && ["shorts", "live"].contains(parts[0]))) { id = parts[1] }
            else { id = nil }
            guard let id else { throw LibraryError.unsupportedEmbed }
            return try WebEmbed(provider: .youtube, videoID: id)
        }
        if ["vimeo.com", "www.vimeo.com", "player.vimeo.com"].contains(host) {
            let id: String
            let hash: String?
            if host == "player.vimeo.com", parts.count == 2, parts[0] == "video" {
                id = parts[1]; hash = try single("h")
            } else if host != "player.vimeo.com", (1...2).contains(parts.count) {
                id = parts[0]
                let queryHash = try single("h")
                guard parts.count == 1 || queryHash == nil else { throw LibraryError.unsupportedEmbed }
                hash = parts.count == 2 ? parts[1] : queryHash
            } else { throw LibraryError.unsupportedEmbed }
            return try WebEmbed(provider: .vimeo, videoID: id, privacyHash: hash)
        }
        throw LibraryError.unsupportedEmbed
    }

    public var pageURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = provider == .youtube ? "www.youtube.com" : "vimeo.com"
        c.path = provider == .youtube ? "/watch" : "/" + videoID
        c.queryItems = provider == .youtube ? [URLQueryItem(name: "v", value: videoID)] : privacyHash.map { [URLQueryItem(name: "h", value: $0)] }
        return c.url!
    }
}

extension Wallpaper {
    public static func web(_ text: String) throws -> Wallpaper {
        let embed = try WebEmbed.parse(text)
        return Wallpaper(title: "\(embed.provider == .youtube ? "YouTube" : "Vimeo") · \(embed.videoID)", kind: .video, source: .web(embed: embed))
    }
}
