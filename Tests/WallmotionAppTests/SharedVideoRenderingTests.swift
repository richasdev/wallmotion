import AppKit
import AVFoundation
import CoreImage
import Darwin
import XCTest
@testable import Wallmotion

/// Opt-in: opens two small QA windows; reads only this process's counters.
@MainActor
final class SharedVideoRenderingTests: XCTestCase {
    @MainActor private final class Scene {
        var pools: [SharedVideoPlayback] = []
        var windows: [NSWindow] = []
        var layers: [AVPlayerLayer] = []
        func stop() {
            pools.forEach { $0.stop() }
            layers.forEach { $0.player = nil }
            windows.forEach { $0.orderOut(nil);$0.close() }
        }
    }

    private func scene(url: URL, shared: Bool) throws -> Scene {
        _ = NSApplication.shared
        let scene = Scene()
        let screen = try XCTUnwrap(NSScreen.main)
        do {
            for index in 0..<2 {
                let pool: SharedVideoPlayback
                if shared, let first = scene.pools.first { pool = first }
                else {
                    pool = try SharedVideoPlayback(wallpaperID: UUID(),url: url) { XCTFail("Native layers did not become ready") }
                    scene.pools.append(pool)
                }
                let frame = CGRect(x: screen.visibleFrame.minX + 10 + CGFloat(index)*180,
                    y: screen.visibleFrame.minY + 10,width: 160,height: 90)
                let view = NSView(frame: CGRect(origin: .zero,size: frame.size));view.wantsLayer = true
                let layer = AVPlayerLayer(player: pool.player);layer.frame = view.bounds;layer.videoGravity = .resizeAspect
                view.layer?.addSublayer(layer);scene.layers.append(layer)
                let window = NSWindow(contentRect: frame,styleMask: [.titled],backing: .buffered,defer: false)
                window.title = "Wallmotion QA \(index+1)";window.isReleasedWhenClosed = false
                window.contentView = view;window.orderFront(nil);scene.windows.append(window)
                let id = pool.subscribe(layer: layer,refresh: {},state: { _ in },error: { XCTFail($0) })
                pool.update(id,playing: true,visible: true,volume: 0)
            }
            return scene
        } catch { scene.stop();throw error }
    }

    private func ready(_ scene: Scene) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if scene.layers.allSatisfy({ $0.isReadyForDisplay }),
               scene.pools.allSatisfy({ !$0.hasFailed && $0.player.timeControlStatus == .playing }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Two native layers must actually display video");throw Failure.notReady
    }
    private enum Failure: Error { case notReady, counters }

    func testNativeSharedLayersDisplayTheSamePausedFrame() async throws {
        guard ProcessInfo.processInfo.environment["WALLMOTION_SHARED_VIDEO_RENDER_QA"] == "1" else {
            throw XCTSkip("Opt-in native windows: WALLMOTION_SHARED_VIDEO_RENDER_QA=1")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionLayerQA-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("generated.mp4");try await LocalVideoFixture.write(at: url)
        let scene = try scene(url: url,shared: true);defer { scene.stop() }
        try await ready(scene)
        let player = try XCTUnwrap(scene.pools.first?.player)
        XCTAssertTrue(scene.layers.allSatisfy { $0.player === player })
        player.pause();try await Task.sleep(for: .milliseconds(150))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var samples: [[UInt8]] = []
        for layer in scene.layers {
            let buffer = try XCTUnwrap(layer.displayedPixelBuffer())
            XCTAssertEqual(CVPixelBufferGetWidth(buffer),32);XCTAssertEqual(CVPixelBufferGetHeight(buffer),16)
            var bytes = [UInt8](repeating: 0,count: 4)
            context.render(CIImage(cvPixelBuffer: buffer),toBitmap: &bytes,rowBytes: 4,
                bounds: CGRect(x: 16,y: 8,width: 1,height: 1),format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            samples.append(bytes)
        }
        XCTAssertEqual(samples[0],samples[1]);XCTAssertGreaterThan(samples[0][2],100)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
    }

    private func counters() throws -> rusage_info_v6 {
        var value = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &value) {
            proc_pid_rusage(getpid(),RUSAGE_INFO_V6,UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard status == 0 else { throw Failure.counters }
        return value
    }

    func testOptInNativeTransportResourceComparison() async throws {
        guard let output = ProcessInfo.processInfo.environment["WALLMOTION_SHARED_VIDEO_BENCHMARK"], !output.isEmpty else {
            throw XCTSkip("Opt-in resource comparison: WALLMOTION_SHARED_VIDEO_BENCHMARK=/tmp/new-file.json")
        }
        // Never overwrite existing evidence. No arbitrary PID or privileges.
        guard !FileManager.default.fileExists(atPath: output) else { XCTFail("Output already exists");return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVideoBench-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("generated.mp4")
        try await LocalVideoFixture.write(at: url,width: 1280,height: 720,frames: 120,fps: 30)
        var rows: [[String: Any]] = []
        for shared in [false,true,false] {
            let scene = try scene(url: url,shared: shared)
            do {
                try await ready(scene)
                try await Task.sleep(for: .seconds(5))
                let before = try counters(), start = ContinuousClock.now
                try await Task.sleep(for: .seconds(30))
                let elapsed = start.duration(to: .now), after = try counters()
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds)/1e18
                let cpuNS = (after.ri_user_time - before.ri_user_time) + (after.ri_system_time - before.ri_system_time)
                XCTAssertEqual(before.ri_proc_start_abstime,after.ri_proc_start_abstime)
                XCTAssertTrue(scene.layers.allSatisfy { $0.isReadyForDisplay })
                XCTAssertTrue(scene.pools.allSatisfy { !$0.hasFailed && $0.player.isMuted && $0.player.volume == 0 && !$0.player.preventsDisplaySleepDuringVideoPlayback })
                rows.append(["shared": shared,"players": scene.pools.count,"layers": scene.layers.count,
                    "seconds": seconds,"cpu_percent": Double(cpuNS)/1e9/seconds*100,
                    "cycles": after.ri_cycles - before.ri_cycles,"instructions": after.ri_instructions - before.ri_instructions,
                    "task_cpu_energy_nj": after.ri_energy_nj - before.ri_energy_nj,
                    "footprint_before": before.ri_phys_footprint,"footprint_after": after.ri_phys_footprint])
                scene.stop()
                try await Task.sleep(for: .seconds(2))
            } catch { scene.stop();throw error }
        }
        let report: [String: Any] = ["schema_version": 1,"os": ProcessInfo.processInfo.operatingSystemVersionString,
            "source": "RUSAGE_INFO_V6, current XCTest process only", "rows": rows,
            "limits": "Fixed A-B-A order; 1280x720 H264, two 160x90 layers; one run in XCTest. CPU energy accounting excludes total GPU/system/battery energy; footprint endpoints are not peaks or causal estimates. No HDR or physical multi-monitor certification."]
        try JSONSerialization.data(withJSONObject: report,options: [.sortedKeys,.prettyPrinted])
            .write(to: URL(fileURLWithPath: output),options: .withoutOverwriting)
    }
}
