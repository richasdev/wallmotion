import Foundation
import WallmotionCore

struct MediaURLDraft: Identifiable {
    let id = UUID()
    var text = ""
    var web = false
}

/// Classifies a drop without I/O. Only the caller decides when to import/save.
@MainActor
enum MediaDropIntent {
    case files([URL]), link(MediaURLDraft), rejected(String)

    static func classify(_ urls: [URL]) -> Self {
        guard !urls.isEmpty else { return .rejected("Nenhum arquivo ou link foi recebido.") }
        guard urls.count <= LibraryModel.maximumImportURLsPerCycle else {
            return .rejected("Importe até 256 arquivos por vez ou arraste um único link HTTPS.")
        }
        if urls.allSatisfy(\.isFileURL) { return .files(urls) }
        guard !urls.contains(where: \.isFileURL) else {
            return .rejected("Arraste arquivos e links separadamente. Este lote não foi adicionado.")
        }
        guard urls.count == 1 else { return .rejected("Arraste um link por vez para revisar antes de adicionar.") }
        let text = urls[0].absoluteString
        guard text.utf8.prefix(4097).count <= 4096 else {
            return .rejected("Este link é muito longo. Use uma URL de até 4096 bytes.")
        }
        if (try? WebEmbed.parse(text)) != nil { return .link(MediaURLDraft(text: text, web: true)) }
        do {
            _ = try MediaURL.validate(text)
            return .link(MediaURLDraft(text: text))
        } catch LibraryError.webPageURL {
            return .rejected("Arraste um vídeo individual do YouTube/Vimeo ou um link HTTPS direto de vídeo/HLS.")
        } catch { return .rejected(error.localizedDescription) }
    }
}
