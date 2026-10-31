// Injected only into a private QA archive by qa-runtime-matrix.py.
// This file is outside every production SwiftPM source target.
import AppKit
import AVFoundation
import WallmotionCore

@MainActor
final class RuntimeMatrixQA {
    static let shared = RuntimeMatrixQA()
    static let root = URL(fileURLWithPath: __QA_ROOT_JSON__, isDirectory: true)
    private var visible = true
    private var pressure = ThermalPausePolicy.Pressure.nominal
    private var window: NSWindow?
    private weak var model: LibraryModel?
    private var watcher: (any DispatchSourceFileSystemObject)?
    private var task: Task<Void, Never>?
    private var lastCommand = -1
    private var phase = "initializing"
    private var player: AVPlayer? { (window?.contentView as? VideoSurface)?.playerLayer.player }

    static func makeModel(store: LibraryStore) -> LibraryModel {
        let engine = DesktopCoordinator(targets: {
            guard let screen = NSScreen.screens.first else { return [] }
            return [DesktopTarget(id: "qa-matrix", screen: screen,
                frame: CGRect(x: -10000, y: -10000, width: 1280, height: 720))]
        }, isWindowVisible: { window in
            shared.window = window
            return shared.visible
        })
        let model = LibraryModel(thermalState: { shared.pressure }, purgeThumbnails: {}, store: store,
            engine: engine, connectedDisplays: { [Display(id: "qa-matrix", name: "QA synthetic target")] })
        shared.model = model
        return model
    }

    static func begin(_ session: ApplicationSession) {
        shared.task = Task { @MainActor in
            do {
                guard let model = session.model, !NSScreen.screens.isEmpty else { throw Failure.unavailable }
                model.setPauseOnLowPower(false);model.setPauseOnMemoryPressure(false)
                model.setPauseOnThermalPressure(true)
                let video = root.appendingPathComponent("generated.mp4")
                try await writeVideo(video)
                await model.importFiles([video])
                guard let item = model.state.wallpapers.first, item.kind == .video else { throw Failure.unavailable }
                model.apply(item, to: "qa-matrix")
                try await shared.waitFor(playing: true)
                shared.phase = "active"
                try shared.publish(id: 0)
                let fd = open(root.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Failure.unavailable }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                source.setEventHandler { Task { @MainActor in shared.receive() } }
                source.setCancelHandler { close(fd) }
                shared.watcher = source;source.resume()
                shared.receive()
            } catch { shared.publishFailure() }
        }
    }

    private func receive() {
        do {
            let path = Self.root.appendingPathComponent("command.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return }
            let data = try Data(contentsOf: path)
            guard data.count <= 4096, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["id"] as? Int, id > lastCommand,
                  let next = value["phase"] as? String,
                  ["active", "manual_pause", "occluded", "thermal_pause"].contains(next) else { return }
            lastCommand = id;task?.cancel()
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let model = self.model, let window = self.window else { throw Failure.unavailable }
                    self.visible = next != "occluded"
                    self.pressure = next == "thermal_pause" ? .serious : .nominal
                    // Hard policy first: a thermal/occlusion request cannot briefly resume audio.
                    if next == "thermal_pause" { model.refreshThermalState() }
                    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
                    if model.state.settings.isManuallyPaused != (next == "manual_pause") { model.togglePause() }
                    if next != "thermal_pause" { model.refreshThermalState() }
                    try await self.waitFor(playing: next == "active")
                    try Task.checkCancellation()
                    guard self.lastCommand == id else { return }
                    self.phase = next
                    try self.publish(id: id)
                } catch is CancellationError { return }
                catch { self.publishFailure() }
            }
        } catch { publishFailure() }
    }

    private func waitFor(playing: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let player, player.currentItem?.status == .failed { throw Failure.unavailable }
            if let player, player.currentItem?.status == .readyToPlay,
               (playing ? player.timeControlStatus == .playing : player.rate == 0) {
                if playing {
                    let previous = player.currentTime()
                    try await Task.sleep(for: .milliseconds(150))
                    if player.currentTime() == previous { continue }
                }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.unavailable
    }

    private func publish(id: Int) throws {
        guard let player else { throw Failure.unavailable }
        let value: [String: Any] = ["id": id, "phase": phase, "pid": Int(getpid()), "status": "ready",
            "playing": player.timeControlStatus == .playing, "rate": player.rate,
            "prevents_display_sleep": player.preventsDisplaySleepDuringVideoPlayback,
            "muted": player.isMuted, "volume": player.volume,
            "current_item_ready": player.currentItem?.status == .readyToPlay]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: Self.root.appendingPathComponent("status.json"), options: .atomic)
    }
    private func publishFailure() {
        let value: [String: Any] = ["id": lastCommand, "status": "failed", "pid": Int(getpid())]
        try? JSONSerialization.data(withJSONObject: value).write(to: Self.root.appendingPathComponent("status.json"), options: .atomic)
    }
    private enum Failure: Error { case unavailable }

    static func writeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw Failure.unavailable }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw Failure.unavailable }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.unavailable }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<120 {
            let deadline = ContinuousClock.now + .seconds(5)
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData, writer.status == .writing else { throw Failure.unavailable }
            var optional: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &optional) == kCVReturnSuccess, let buffer = optional else { throw Failure.unavailable }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw Failure.unavailable }
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1280, height: 720,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw Failure.unavailable }
                context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 1280,height: 720))
                context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
                context.fill(CGRect(x: (index * 12) % 1280,y: 160,width: 180,height: 300))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw Failure.unavailable }
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1));input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.unavailable }
    }
}
