import SwiftUI
import WallmotionCore

struct RenameMediaSheet: View {
    @State private var title: String
    @State private var saveError: String?
    @FocusState private var isFocused: Bool
    let canSave: Bool
    let onSave: (String) -> String?
    let onCancel: () -> Void

    init(title: String, canSave: Bool, onSave: @escaping (String) -> String?, onCancel: @escaping () -> Void) {
        _title = State(initialValue: title)
        self.canSave = canSave
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var validationError: String? {
        do { _ = try MediaTitle.normalized(title); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Renomear mídia", systemImage: "pencil").font(.title2.weight(.semibold))
            Text("O novo nome aparece na biblioteca e nos monitores. O arquivo e a reprodução atual são preservados.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Nome da mídia", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onChange(of: title) { _, _ in saveError = nil }
                .onSubmit(save)
            if let error = saveError ?? validationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Até 200 caracteres").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Salvar", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canSave || validationError != nil)
            }
        }
        .padding(28).frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave, validationError == nil else { return }
        saveError = onSave(title)
    }
}
