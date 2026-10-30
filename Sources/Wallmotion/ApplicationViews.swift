import SwiftUI
import AppKit

// Read admission state inside View bodies so Observation updates every window,
// menu and command after the application delegate admits a primary instance.
struct LibraryWindowContent: View {
    let session: ApplicationSession
    let events: LaunchEventRouter
    let onRetry: () -> Void
    var body: some View {
        if let model = session.model { LibraryView(model: model) }
        else { StartupStatusView(session: session, events: events, onRetry: onRetry) }
    }
}

struct ApplicationSettingsContent: View {
    let session: ApplicationSession
    let events: LaunchEventRouter
    let onRetry: () -> Void
    var body: some View {
        if session.model != nil { SettingsView() }
        else { StartupStatusView(session: session, events: events, onRetry: onRetry).frame(width: 440, height: 320) }
    }
}

struct ApplicationMenuContent: View {
    let session: ApplicationSession
    var body: some View {
        if let model = session.model { WallpaperMenu(model: model) }
        else {
            Text("Biblioteca em uso ou indisponível")
            Button("Encerrar esta instância") { NSApp.terminate(nil) }
        }
    }
}

struct ImportMediaCommand: View {
    let session: ApplicationSession
    var body: some View {
        Button("Importar mídia…") { session.model?.chooseFiles() }
            .keyboardShortcut("o").disabled(session.model == nil)
    }
}
