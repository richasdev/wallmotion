import AppKit
import AVFoundation
import CoreVideo
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class LiveHLSMatrixTests: XCTestCase {
    private enum Failure: Error { case unavailable, outputExists }

    func testOptInNativeHLSPresetTransitionsKeepItemAndRecordActualPresentation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["WALLMOTION_HLS_QA_URL"],
              let output = environment["WALLMOTION_HLS_QA_OUTPUT"] else {
            throw XCTSkip("Opt-in live HLS: WALLMOTION_HLS_QA_URL and new WALLMOTION_HLS_QA_OUTPUT JSON path")
        }
        guard !FileManager.default.fileExists(atPath: output) else { throw Failure.outputExists }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let url = try MediaURL.validate(text), wallpaper = try Wallpaper.remote(text)
        var failure = false
        let renderer = try WallpaperRenderer(wallpaper: wallpaper,url: url,screen: screen,
            isWindowVisible: { _ in true }) { _ in failure = true }
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView as? VideoSurface)
        let player = try XCTUnwrap(surface.playerLayer.player)
        let item = try XCTUnwrap(player.currentItem)
        renderer.setPaused(false)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, !failure,
              !(item.status == .readyToPlay && player.timeControlStatus == .playing && surface.playerLayer.isReadyForDisplay) {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !failure, item.status == .readyToPlay, player.timeControlStatus == .playing,
              surface.playerLayer.isReadyForDisplay else { XCTFail("Native HLS failed readiness");throw Failure.unavailable }
        var rows: [[String: Any]] = []
        for preset in [HLSResolution.automatic,.hd720,.uhd2160,.automatic] {
            renderer.setHLSResolution(preset)
            XCTAssertTrue(player.currentItem === item,"Changing preference must not replace or seek the item")
            let expected = preset.maximumDimensions.map { CGSize(width: $0.width,height: $0.height) } ?? .zero
            XCTAssertEqual(item.preferredMaximumResolution,expected)
            let before = player.currentTime().seconds
            try await Task.sleep(for: .seconds(10))
            let after = player.currentTime().seconds
            guard !failure, player.currentItem === item, item.status == .readyToPlay,
                  player.timeControlStatus == .playing, before.isFinite, after.isFinite, after > before,
                  let buffer = surface.playerLayer.displayedPixelBuffer() else {
                XCTFail("HLS did not remain playing with a native displayed frame");throw Failure.unavailable
            }
            XCTAssertTrue(player.isMuted);XCTAssertEqual(player.volume,0)
            XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
            let attachments = CVBufferCopyAttachments(buffer,.shouldPropagate) as? [String: Any] ?? [:]
            let events = item.accessLog()?.events ?? []
            var row: [String: Any] = ["preset": preset.rawValue,"playhead_before": before,"playhead_after": after,
                "preference_width": expected.width,"preference_height": expected.height,
                "presentation_width": item.presentationSize.width,"presentation_height": item.presentationSize.height,
                "buffer_width": CVPixelBufferGetWidth(buffer),"buffer_height": CVPixelBufferGetHeight(buffer),
                "buffer_pixel_format": CVPixelBufferGetPixelFormatType(buffer),"layer_ready": surface.playerLayer.isReadyForDisplay,
                "muted": player.isMuted,"volume": player.volume,"prevents_display_sleep": player.preventsDisplaySleepDuringVideoPlayback,
                "access_events": events.map { event -> [String: Any] in
                    // Only allowlisted scalars: never URI, server address or raw errors.
                    var value: [String: Any] = ["bytes": event.numberOfBytesTransferred,"stalls": event.numberOfStalls]
                    if event.indicatedBitrate.isFinite { value["indicated_bitrate"] = event.indicatedBitrate }
                    if event.observedBitrate.isFinite { value["observed_bitrate"] = event.observedBitrate }
                    return value
                }]
            for key in [kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey,kCVImageBufferYCbCrMatrixKey] {
                if let value = attachments[key as String] as? String { row[key as String] = value }
            }
            rows.append(row)
        }
        renderer.setPaused(true)
        renderer.setHLSResolution(.fullHD1080)
        XCTAssertTrue(player.currentItem === item);XCTAssertEqual(player.rate,0)
        XCTAssertEqual(item.preferredMaximumResolution,CGSize(width: 1920,height: 1080))
        renderer.stop();XCTAssertNil(player.currentItem);XCTAssertNil(surface.playerLayer.player)
        let report: [String: Any] = ["schema_version": 1,"os": ProcessInfo.processInfo.operatingSystemVersionString,
            "screens": NSScreen.screens.map { ["width_points": $0.frame.width,"height_points": $0.frame.height,
                "scale": $0.backingScaleFactor,"edr_current": $0.maximumExtendedDynamicRangeColorComponentValue,
                "edr_potential": $0.maximumPotentialExtendedDynamicRangeColorComponentValue] },
            "rows": rows,"limits": "One opted-in URL, short fixed-order sample. Ten seconds may retain buffered variants. Preference is not a guaranteed cap. Color metadata and EDR capability do not certify visual color, no flicker, HDR/SDR transition, portrait physical display, energy or CPU improvement. No source URLs or raw errors exported."]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: output),options: .withoutOverwriting)
    }
}
