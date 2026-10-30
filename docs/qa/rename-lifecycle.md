# Rename sheet lifecycle

Issue #126: LibraryView observes the existence of the pending rename ID. If the record disappears, the sheet binding is cleared. Save availability also requires the record to exist, and the save closure rechecks it immediately before invoking the model. It closes a stale sheet without attempting another state write or emitting a missing-item error. Actual persistence failures continue to stay visible for retry.

The existence projection is a Boolean; this adds no ID-array allocation, polling or filesystem access. The initializer accepts an optional initial rename target for deterministic component testing, defaulting to no sheet in production.

A temporary-library component test creates the real LibraryView in an offscreen NSWindow, verifies that an actual SwiftUI rename sheet is presented, removes the target through the model, and verifies that the sheet disappears. It also checks unchanged library bytes after removal and no error. The test passed without TCC/Accessibility changes or interaction with the user’s running app. This does not certify VoiceOver or concurrent physical clicks in multiple windows.
