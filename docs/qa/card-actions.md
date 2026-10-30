# Visible media rename action

`WallpaperCard` is extracted into its own SwiftUI source file and now shows a pencil button beside removal in the metadata row. The button uses the existing rename callback/sheet, an explicit Renomear <title> accessibility label and a tooltip. Context-menu rename and the named accessibility action remain available. The library's existing read-only disable boundary covers the whole card; having no selected/connected display disables Apply while library management remains available.

No preview players, I/O, persistent settings or new hover state are introduced. Type labels use an exhaustive MediaKind switch instead of constructing a dictionary during card evaluation. The title validation and transactional rename behavior remain in the existing model/sheet tests.

The existing temporary-library fixture is used for dark/light wide-window snapshots, keeping the full card and action row visible. This is composition QA plus compilation/regression checks; actual pointer/keyboard/VoiceOver interaction remains manual under #47. Existing rename model/sheet tests continue to verify title validation and safe publication.
