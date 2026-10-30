import SwiftUI
import AppKit

@main
struct WallmotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Wallmotion", id: "library") {
            LibraryView(model: delegate.model)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar mídia…") { delegate.model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
        MenuBarExtra("Wallmotion", systemImage: "play.rectangle.on.rectangle") {
            WallpaperMenu(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LibraryModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        model.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Wallmotion" })?.makeKeyAndOrderFront(nil)
        Task { @MainActor [weak model] in await model?.importFiles(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first(where: { $0.title == "Wallmotion" })?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct WallpaperMenu: View {
    let model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.playbackDescription)
        Button("Abrir biblioteca") {
            openWindow(id: "library")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.state.settings.isManuallyPaused ? "Retomar wallpapers" : "Pausar wallpapers") { model.togglePause() }
            .disabled(!model.canEdit)
        Button("Recarregar reprodução") { model.refreshPlayback() }
        Divider()
        Button("Encerrar Wallmotion") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
