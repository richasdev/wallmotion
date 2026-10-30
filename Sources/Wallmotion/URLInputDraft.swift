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

    /// Returns true for an edit attempt (including rejection), false for an exact writeback.
    @discardableResult mutating func replace(with value: String) -> Bool {
        guard Self.accepts(value) else {
            inputError = "O link ultrapassa 4096 bytes e não foi inserido. Edite o campo ou cole uma URL menor."
            return true
        }
        guard !value.utf8.elementsEqual(text.utf8) else { return false }
        text = value
        inputError = nil
        return true
    }
}
