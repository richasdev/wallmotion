// Injected only into a private QA archive. Not a production SwiftPM target.
import AppKit
import WallmotionCore

@MainActor
enum NondefaultLaunchQA {
    static let root = URL(fileURLWithPath: __QA_ROOT_JSON__,isDirectory: true)
    static var task: Task<Void,Never>?
    static var watcher: (any DispatchSourceFileSystemObject)?

    static func begin(_ delegate: AppDelegate, isDefault: Bool, flagPresent: Bool) {
        guard delegate.session.phase == .busy else { return }
        let initial: [String: Any] = ["pid": Int(getpid()),"launch_is_default": isDefault,"launch_flag_present": flagPresent,
            "busy": true,"has_model": delegate.session.model != nil,
            "pending": delegate.events.pendingURLs.count,"waiting": delegate.events.waitingForInitialFiles]
        try? JSONSerialization.data(withJSONObject: initial).write(to: root.appendingPathComponent("launch-\(getpid()).json"),options: .atomic)
        guard !isDefault else { return }
        task = Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                if delegate.events.waitingForInitialFiles, !delegate.events.isForwarding,
                   let window = NSApp.windows.first(where: { $0.title == "Wallmotion" }),
                   let view = window.contentView, view.bounds.width >= 300, view.bounds.height >= 200 {
                    do {
                        view.layoutSubtreeIfNeeded()
                        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds,to: bitmap)
                        // cacheDisplay preserves transparent SwiftUI background;
                        // composite on white for a legible artifact (not an OS screen capture).
                        let image = NSImage(size: view.bounds.size,flipped: false) { rect in
                            NSColor.white.setFill();rect.fill();bitmap.draw(in: rect);return true
                        }
                        guard let tiff = image.tiffRepresentation,let opaque = NSBitmapImageRep(data: tiff),
                              let png = opaque.representation(using: .png,properties: [:]) else { return }
                        try png.write(to: root.appendingPathComponent("status-\(getpid()).png"),options: .withoutOverwriting)
                        let value: [String: Any] = ["pid": Int(getpid()),"status": "waiting", "busy": delegate.session.phase == .busy,
                            "has_model": delegate.session.model != nil,"pending": delegate.events.pendingURLs.count,
                            "waiting": delegate.events.waitingForInitialFiles,"forwarding": delegate.events.isForwarding,
                            "launch_is_default": isDefault,"launch_flag_present": flagPresent,
                            "capture_background": "white composite of native view cache", "width": view.bounds.width,"height": view.bounds.height]
                        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("waiting-\(getpid()).json"),options: .atomic)
                        let fd = open(root.path,O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { return }
                        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,eventMask: .write,queue: .main)
                        source.setCancelHandler { close(fd) }
                        source.setEventHandler { Task { @MainActor in receive(delegate) } }
                        watcher = source;source.resume();receive(delegate)
                    } catch { return }
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private static func receive(_ delegate: AppDelegate) {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("action-command.json")),data.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["pid"] as? Int == Int(getpid()),value["action"] as? String == "activate_and_close",
              delegate.session.phase == .busy,delegate.session.model == nil,
              delegate.events.waitingForInitialFiles,!delegate.events.isForwarding else { return }
        watcher?.cancel();watcher = nil
        try? JSONSerialization.data(withJSONObject: ["pid": Int(getpid()),"action": "activate_and_close"])
            .write(to: root.appendingPathComponent("action-\(getpid()).json"),options: .atomic)
        delegate.events.activateAndClose()
    }
}
