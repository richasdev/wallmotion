/// Bounded editable URL state. Syntax/provider validation remains separate.
struct URLInputDraft: Sendable {
    static let maximumBytes = 4096
    private(set) var text: String
    private(set) var inputError: String?

    init(text: String) {
        if Self.accepts(text) {
            self.text = text
        } else {
            self.text = ""
            inputError = "O link recebido é muito longo. Cole uma URL menor para continuar."
        }
    }

    static func accepts(_ text: String) -> Bool {
        text.utf8.prefix(maximumBytes + 1).count <= maximumBytes
    }

    mutating func replace(with value: String) {
        guard value != text else { return } // Text-field reconciliation is not a new edit.
        guard Self.accepts(value) else {
            inputError = "O link ultrapassa 4096 bytes e não foi inserido. Edite o campo ou cole uma URL menor."
            return
        }
        text = value
        inputError = nil
    }
}
