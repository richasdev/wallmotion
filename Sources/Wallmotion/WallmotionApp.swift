import SwiftUI
import AppKit

@main
struct WallmotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        libraryWindow
        Settings {
            ApplicationSettingsContent(session: delegate.session, events: delegate.events, onRetry: delegate.retryStartup)
        }
        .commands {
            CommandGroup(after: .textEditing) { LibrarySearchCommand() }
            CommandGroup(replacing: .newItem) {
                ImportMediaCommand(session: delegate.session)
            }
        }
        MenuBarExtra {
            ApplicationMenuContent(session: delegate.session)
        } label: {
            Image(nsImage: WallmotionMenuIcon.image)
                .accessibilityLabel("Wallmotion")
        }
    }

    private var libraryWindow: some Scene {
        Window("Wallmotion", id: "library") {
            LibraryWindowContent(session: delegate.session, events: delegate.events, onRetry: delegate.retryStartup)
                .frame(minWidth: 820, minHeight: 560)
                .background(CompactLibraryWindow().frame(width: 0, height: 0).allowsHitTesting(false))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(LibraryWindowStartup.contentSize)
        .windowResizability(.contentMinSize)
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = ApplicationSession()
    private lazy var workspace = InstanceWorkspace(rootURL: session.rootURL,
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.richas.wallmotion")
    lazy var events = LaunchEventRouter(
        isPrimary: { [weak self] in self?.session.model != nil },
        isBusy: { [weak self] in self?.session.phase == .busy },
        importURLs: { [weak self] urls in self?.importIntoPrimary(urls) },
        activateOwner: { [weak self] in
            guard let self else { throw InstanceWorkspace.Failure.ownerUnavailable }
            try await self.workspace.activate()
        },
        forward: { [weak self] urls in
            guard let self else { throw InstanceWorkspace.Failure.ownerUnavailable }
            try await self.workspace.forward(urls)
        },
        terminate: { NSApp.terminate(nil) },
        onRejection: { [weak self] message in
            guard let self, let model = self.session.model else { return }
            model.errorMessage = message
            self.showLibrary()
        })

    func applicationWillFinishLaunching(_ notification: Notification) { session.prepare() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        // Keep a fallback for direct/test launch paths which omit willFinish.
        if session.phase == .preparing { session.prepare() }
        session.finishLaunching()
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
        events.finishLaunching(isDefaultLaunch: isDefault)
    }

    func application(_ application: NSApplication, open urls: [URL]) { events.receive(urls) }

    private func importIntoPrimary(_ urls: [URL]) {
        guard let model = session.model else { return }
        showLibrary()
        Task { @MainActor [weak model] in await model?.importFiles(urls) }
    }

    func retryStartup() {
        guard !events.isForwarding else { return }
        session.prepare()
        events.retry()
    }

    private func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "Wallmotion" })?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { session.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        if session.model == nil { events.retry() }
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
        Button(model.manualPauseActionTitle) { model.togglePause() }
            .disabled(!model.canEdit)
        Toggle("Pausar com outros apps visíveis", isOn: Binding(
            get: { model.state.settings.pauseWhenOtherAppsVisible },
            set: { model.setPauseWhenOtherAppsVisible($0) }
        )).disabled(!model.canEdit)
        Button(model.state.settings.audioDisplayID == nil ? "Ativar som" : "Desativar som") {
            model.toggleAudioPermission()
        }
        .disabled(!model.canEdit || (model.state.settings.audioDisplayID == nil &&
                  !model.displays.contains(where: { model.audioWallpaper(on: $0.id) != nil })))
        Menu("Volume geral · \(Int((model.state.settings.audioVolume * 100).rounded()))%") {
            ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                Button("\(percent)%") { model.setAudioVolume(Double(percent) / 100) }
            }
        }.disabled(!model.canEdit || model.state.settings.audioDisplayID == nil)
        if let display = model.state.settings.audioDisplayID,
           model.displays.contains(where: { $0.id == display }),
           let item = model.audioWallpaper(on: display) {
            Menu("Volume do fundo com som · \(Int((model.state.audioGain(for: item.id) * 100).rounded()))%") {
                ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                    Button("\(percent)%") { model.setAudioGain(Double(percent) / 100, for: item.id) }
                }
            }.disabled(!model.canEdit)
        }
        Button("Recarregar reprodução") { model.refreshPlayback() }
        Divider()
        Button("Encerrar Wallmotion") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
