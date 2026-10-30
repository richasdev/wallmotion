import Foundation

/// A single official provider embed. Never a stream URL or arbitrary web page.
public struct WebEmbed: Codable, Equatable, Sendable {
    public enum Provider: String, Codable, Sendable { case youtube, vimeo }
    public let provider: Provider
    public let videoID: String
    public let privacyHash: String?
    public let startSeconds: Int
    public static let maximumStartSeconds = Int(Int32.max)

    public init(provider: Provider, videoID: String, privacyHash: String? = nil, startSeconds: Int = 0) throws {
        self.provider = provider
        self.videoID = videoID
        self.privacyHash = privacyHash
        self.startSeconds = startSeconds
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case provider, videoID, privacyHash, startSeconds }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: values.decode(Provider.self, forKey: .provider),
                      videoID: values.decode(String.self, forKey: .videoID),
                      privacyHash: values.decodeIfPresent(String.self, forKey: .privacyHash),
                      startSeconds: values.decodeIfPresent(Int.self, forKey: .startSeconds) ?? 0)
    }

    public func validate() throws {
        guard (0...Self.maximumStartSeconds).contains(startSeconds), provider == .youtube || startSeconds == 0 else {
            throw LibraryError.unsupportedEmbed
        }
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
        guard text.utf8.count <= 4096, !text.contains(where: { $0.isWhitespace }), let c = URLComponents(string: text),
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
            let t = try single("t")
            let start = try single("start")
            let fragmentTime = c.fragment.flatMap { $0.hasPrefix("t=") ? String($0.dropFirst(2)) : nil }
            let specified = [t, start, fragmentTime].compactMap { $0 }
            // Missing values and competing timestamp forms are ambiguous, even if equal.
            guard specified.count <= 1,
                  !query.contains(where: { ["t", "start"].contains($0.name) && $0.value == nil }) else {
                throw LibraryError.unsupportedEmbed
            }
            let seconds = try specified.first.map { try parseStart($0, digitsOnly: start != nil) } ?? 0
            return try WebEmbed(provider: .youtube, videoID: id, startSeconds: seconds)
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

    private static func parseStart(_ value: String, digitsOnly: Bool) throws -> Int {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 32 else { throw LibraryError.unsupportedEmbed }
        func boundedNumber(_ digits: ArraySlice<UInt8>) throws -> Int {
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { throw LibraryError.unsupportedEmbed }
            var result = 0
            for byte in digits {
                guard result <= (maximumStartSeconds - Int(byte - 48)) / 10 else { throw LibraryError.unsupportedEmbed }
                result = result * 10 + Int(byte - 48)
            }
            return result
        }
        if bytes.allSatisfy({ (48...57).contains($0) }) { return try boundedNumber(bytes[...]) }
        guard !digitsOnly else { throw LibraryError.unsupportedEmbed }
        var start = 0
        var previousMultiplier = Int.max
        var total = 0
        for index in bytes.indices where !(48...57).contains(bytes[index]) {
            let multiplier: Int
            switch bytes[index] {
            case 104: multiplier = 3600
            case 109: multiplier = 60
            case 115: multiplier = 1
            default: throw LibraryError.unsupportedEmbed
            }
            guard multiplier < previousMultiplier else { throw LibraryError.unsupportedEmbed }
            let number = try boundedNumber(bytes[start..<index])
            guard number <= (maximumStartSeconds - total) / multiplier else { throw LibraryError.unsupportedEmbed }
            total += number * multiplier
            previousMultiplier = multiplier
            start = index + 1
        }
        guard start == bytes.count else { throw LibraryError.unsupportedEmbed }
        return total
    }

    public var startTimeLabel: String {
        let seconds = startSeconds % 60
        let minutes = (startSeconds / 60) % 60
        let hours = startSeconds / 3600
        let paddedSeconds = seconds < 10 ? "0\(seconds)" : String(seconds)
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : String(minutes)
        return hours > 0 ? "\(hours):\(paddedMinutes):\(paddedSeconds)" : "\(startSeconds / 60):\(paddedSeconds)"
    }

    public var pageURL: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = provider == .youtube ? "www.youtube.com" : "vimeo.com"
        c.path = provider == .youtube ? "/watch" : "/" + videoID
        c.queryItems = provider == .youtube ? [URLQueryItem(name: "v", value: videoID)] : privacyHash.map { [URLQueryItem(name: "h", value: $0)] }
        if provider == .youtube, startSeconds > 0 { c.queryItems?.append(URLQueryItem(name: "t", value: String(startSeconds))) }
        return c.url!
    }
}

extension Wallpaper {
    public static func web(_ text: String) throws -> Wallpaper {
        let embed = try WebEmbed.parse(text)
        let start = embed.startSeconds > 0 ? " · \(embed.startTimeLabel)" : ""
        return Wallpaper(title: "\(embed.provider == .youtube ? "YouTube" : "Vimeo") · \(embed.videoID)\(start)", kind: .video, source: .web(embed: embed))
    }
}
