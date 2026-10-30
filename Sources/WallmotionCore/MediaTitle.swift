import Foundation

public enum MediaTitle {
    public static let maximumCharacters = 200

    public static func normalized(_ text: String) throws -> String {
        // A single grapheme can contain arbitrarily many combining scalars.
        guard text.utf8.count <= 4096 else { throw MediaTitleError.tooLong }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MediaTitleError.empty }
        guard title.count <= maximumCharacters else { throw MediaTitleError.tooLong }
        guard !title.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029
                || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }) else { throw MediaTitleError.invalidCharacters }
        return title
    }
}

public enum MediaTitleError: LocalizedError, Equatable {
    case empty, tooLong, invalidCharacters
    public var errorDescription: String? {
        switch self {
        case .empty: "Digite um nome para esta mídia."
        case .tooLong: "Nome longo demais. Reduza o texto e use até 200 caracteres."
        case .invalidCharacters: "Use um nome em uma linha, sem caracteres de controle."
        }
    }
}
