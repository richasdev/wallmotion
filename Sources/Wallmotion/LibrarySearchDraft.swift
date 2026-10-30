/// Bounds retained UI query text; the core query projection remains unrestricted.
struct LibrarySearchDraft: Sendable {
    static let maximumBytes = 4096
    private(set) var text: String
    private(set) var notice: String?
    private static let limitNotice = "A busca é muito longa. Digite um trecho menor do título."

    init(text: String = "") {
        if Self.accepts(text) { self.text = text }
        else { self.text = ""; notice = Self.limitNotice }
    }

    static func accepts(_ value: String) -> Bool {
        value.utf8.prefix(maximumBytes + 1).count <= maximumBytes
    }

    /// Exact writebacks preserve the notice; valid edits and explicit clear acknowledge it.
    @discardableResult mutating func replace(with value: String) -> Bool {
        guard Self.accepts(value) else { notice = Self.limitNotice; return true }
        guard !value.utf8.elementsEqual(text.utf8) else { return false }
        text = value
        notice = nil
        return true
    }

    mutating func clear() {
        text = ""
        notice = nil
    }
}
