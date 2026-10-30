import Foundation

/// Provider errors are untrusted text; expose actionable known categories, never
/// raw SDK descriptions, URLs, privacy hashes or NSError userInfo.
public enum WebPlaybackFailure {
    public static func identifier(from code: String) -> String {
        let bounded = String(decoding: code.utf8.prefix(96), as: UTF8.self)
        let token = String(bounded.split(separator: ":", maxSplits: 1).first ?? "")
        return switch token {
        case "2", "5", "100", "101", "150", "153", "sdk-load", "autoplay-blocked",
             "PrivacyError", "PasswordError", "PlaybackError": token
        default: "unknown"
        }
    }

    public static func message(provider: WebEmbed.Provider, code: String) -> String {
        let name = provider == .youtube ? "YouTube" : "Vimeo"
        let key = identifier(from: code)
        if key == "sdk-load" { return "Não foi possível carregar o player do \(name). Confira a conexão e tente novamente." }
        if key == "autoplay-blocked" { return "O \(name) bloqueou a reprodução automática. Desative o som e tente recarregar ou escolha outro vídeo público." }
        switch (provider, key) {
        case (.youtube, "100"):
            return "O vídeo do YouTube não foi encontrado ou está privado. Escolha outro vídeo público."
        case (.youtube, "101"), (.youtube, "150"):
            return "O responsável pelo vídeo desativou a incorporação no YouTube. Escolha outro vídeo."
        case (.youtube, "153"):
            return "O YouTube recusou a identificação de origem do player (153). Tente recarregar ou escolha outro vídeo público."
        case (.youtube, "2"):
            return "O YouTube rejeitou os parâmetros do vídeo (2). Confira o link e tente novamente."
        case (.youtube, "5"):
            return "O YouTube não conseguiu reproduzir este vídeo no player HTML5 (5). Tente outro vídeo."
        case (.vimeo, "PrivacyError"):
            return "O Vimeo bloqueou o acesso ou a incorporação deste vídeo. Para links não listados, cole o endereço completo com o identificador de privacidade. Login não é suportado."
        case (.vimeo, "PasswordError"):
            return "Este vídeo do Vimeo exige senha. Use um vídeo público que permita incorporação."
        case (.vimeo, "PlaybackError"):
            return "O Vimeo não conseguiu reproduzir este vídeo e não informou a causa. Tente outro vídeo público ou confira sua disponibilidade no navegador."
        default:
            return "O player do \(name) não iniciou. Confira a conexão e se o vídeo permite incorporação pública."
        }
    }

    public static func navigationMessage(provider: WebEmbed.Provider, error: any Error) -> String {
        let name = provider == .youtube ? "YouTube" : "Vimeo"
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut:
                return "O player do \(name) não carregou a tempo. Confira a conexão e tente novamente."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return "A conexão segura com o \(name) falhou. Confira a data do sistema e tente novamente."
            default: break
            }
        }
        return "Não foi possível carregar o player do \(name). Confira a conexão e tente novamente."
    }
}
