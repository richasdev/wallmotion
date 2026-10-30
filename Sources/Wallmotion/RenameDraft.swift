import Foundation
import WallmotionCore

/// Bounded editable state; rejected input never silently replaces an accepted name.
struct RenameDraft: Sendable {
    enum CounterState: Sendable, Equatable { case normal, nearLimit, exceeded }
    static let maximumDraftCharacters = 256
    static let maximumDraftBytes = 4096
    private(set) var text: String
    private(set) var inputError: String?

    init(text: String) {
        if Self.accepts(text) {
            self.text = text
        } else {
            self.text = ""
            inputError = "O nome atual é muito extenso. Digite um novo nome ou cancele para preservá-lo."
        }
    }

    static func accepts(_ text: String) -> Bool {
        guard text.utf8.prefix(maximumDraftBytes + 1).count <= maximumDraftBytes else { return false }
        return text.prefix(maximumDraftCharacters + 1).count <= maximumDraftCharacters
    }

    /// Returns true for an edit attempt (including rejection), false for an exact writeback.
    @discardableResult mutating func replace(with value: String) -> Bool {
        guard Self.accepts(value) else {
            inputError = "O texto é grande demais para este campo. Ele não foi inserido; digite ou cole um nome menor."
            return true
        }
        guard !value.utf8.elementsEqual(text.utf8) else { return false }
        text = value
        inputError = nil
        return true
    }

    var characterCount: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }
    var counterState: CounterState {
        if characterCount > MediaTitle.maximumCharacters { return .exceeded }
        return characterCount >= MediaTitle.maximumCharacters - 20 ? .nearLimit : .normal
    }
    var validationError: String? {
        if let inputError { return inputError }
        do { _ = try MediaTitle.normalized(text); return nil }
        catch { return error.localizedDescription }
    }
}
