import SwiftUI

private struct LibrarySearchActionKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var librarySearchAction: (@MainActor () -> Void)? {
        get { self[LibrarySearchActionKey.self] }
        set { self[LibrarySearchActionKey.self] = newValue }
    }
}

struct LibrarySearchCommand: View {
    @FocusedValue(\.librarySearchAction) private var find
    var body: some View {
        Button("Buscar na biblioteca") { find?() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(find == nil)
    }
}
