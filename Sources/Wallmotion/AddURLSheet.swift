import SwiftUI
import WallmotionCore

/// Local syntax feedback only. Never resolves a URL or reads the clipboard.
struct URLDraftFeedback {
    let summary: String?
    let error: String?
    var isValid: Bool { summary != nil && error == nil }

    init(text: String, web: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            summary = nil
            error = nil
            return
        }
        // Bound interactive parsing, including direct URLs with long query strings.
        guard text.utf8.count <= 4096 else {
            summary = nil
            error = "Este link é muito longo. Use uma URL de até 4096 bytes."
            return
        }
        do {
            if web {
                let embed = try WebEmbed.parse(text)
                let provider = embed.provider == .youtube ? "YouTube" : "Vimeo"
                summary = embed.startSeconds > 0 ? "\(provider) · início em \(embed.startTimeLabel)" : "\(provider) · vídeo individual"
            } else {
                let url = try MediaURL.validate(text)
                summary = url.pathExtension.lowercased() == "m3u8" ? "Link HTTPS · transmissão HLS" : "Link HTTPS · vídeo direto"
            }
            error = nil
        } catch {
            summary = nil
            if !web, (try? WebEmbed.parse(text)) != nil {
                self.error = "Este link é de um provedor. Selecione YouTube / Vimeo acima."
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

struct AddURLSheet: View {
    @State private var text: String
    @State private var web: Bool
    @State private var saveError: String?
    @FocusState private var isFocused: Bool
    let canAdd: Bool
    let onAdd: (String, Bool) -> String?
    let onCancel: () -> Void

    init(text: String = "", web: Bool = false, canAdd: Bool,
         onAdd: @escaping (String, Bool) -> String?, onCancel: @escaping () -> Void) {
        _text = State(initialValue: text)
        _web = State(initialValue: web)
        self.canAdd = canAdd
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    private var feedback: URLDraftFeedback { .init(text: text, web: web) }

    var body: some View {
        let feedback = feedback
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Adicionar vídeo por URL").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Escolha a fonte e cole o link do vídeo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Tipo de fonte", selection: $web) {
                Text("Link direto").tag(false)
                Text("YouTube / Vimeo").tag(true)
            }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 10) {
                Text("URL do vídeo").font(.callout.weight(.medium))
                TextField(web ? "https://www.youtube.com/watch?v=…" : "https://exemplo.com/video.mp4", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("URL do vídeo")
                    .focused($isFocused)
                    .onSubmit(add)
                if let error = saveError ?? feedback.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Não foi possível adicionar. \(error)")
                } else if let summary = feedback.summary {
                    Label(summary, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text(web ? "Vídeo individual do YouTube ou Vimeo; tempos iniciais do YouTube são preservados."
                         : "Use HTTPS de vídeo ou HLS (.m3u8). Páginas web não são reproduzidas como vídeo direto.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Conexão somente ao aplicar", systemImage: "network")
                    .font(.caption.weight(.medium))
                Text("A validação aqui é local e não confirma disponibilidade. Links temporários podem expirar; autoplay e incorporação dependem do provedor. Login e DRM não são suportados.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Adicionar à biblioteca", action: add)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || !feedback.isValid)
            }
        }
        .padding(28).frame(width: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { isFocused = true }
        .onChange(of: text) { _, _ in saveError = nil }
        .onChange(of: web) { _, _ in saveError = nil; isFocused = true }
    }

    private func add() {
        guard canAdd, feedback.isValid else { return }
        saveError = onAdd(text, web)
    }
}
