import SwiftUI
import WallmotionCore

struct RenameMediaSheet: View {
    @State private var draft: RenameDraft
    @Environment(\.colorScheme) private var colorScheme
    @State private var saveError: String?
    @FocusState private var isFocused: Bool
    let canSave: Bool
    let onSave: (String) -> String?
    let onCancel: () -> Void

    init(title: String, canSave: Bool, onSave: @escaping (String) -> String?, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: RenameDraft(text: title))
        self.canSave = canSave
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var counterCaption: String {
        switch draft.counterState {
        case .normal: "Até 200 caracteres"
        case .nearLimit: "Perto do limite"
        case .exceeded: "Limite excedido"
        }
    }

    private var counterColor: Color {
        switch draft.counterState {
        case .normal: .secondary
        case .nearLimit: colorScheme == .dark ? Color(red: 1, green: 0.72, blue: 0.25) : Color(red: 0.52, green: 0.29, blue: 0.04)
        case .exceeded: colorScheme == .dark ? Color(red: 1, green: 0.52, blue: 0.55) : Color(red: 0.66, green: 0.12, blue: 0.16)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Renomear mídia", systemImage: "pencil").font(.title2.weight(.semibold))
            Text("O novo nome aparece na biblioteca e nos monitores. O arquivo e a reprodução atual são preservados.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Nome da mídia", text: Binding(get: { draft.text }, set: {
                var next = draft
                guard next.replace(with: $0) else { return }
                saveError = nil
                draft = next
            }))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
            if let error = saveError ?? draft.validationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(counterCaption).accessibilityHidden(true)
                Spacer()
                Text("\(draft.characterCount)/\(MediaTitle.maximumCharacters)")
                    .monospacedDigit()
                    .accessibilityLabel("\(draft.characterCount) de \(MediaTitle.maximumCharacters) caracteres. \(counterCaption)")
                    .help("Espaços no início e no fim não entram na contagem.")
            }
            .font(.caption).foregroundStyle(counterColor)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave || draft.validationError != nil)
            }
        }
        .padding(28).frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave, draft.validationError == nil else { return }
        saveError = onSave(draft.text)
    }
}
