import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Wallmotion

/// Opt-in controlled decoder stress, not a measurement of real SwiftUI scrolling,
/// process RSS, GPU or energy. Uses only temporary media and bypasses NSCache.
final class ThumbnailStressTests: XCTestCase {
    private final class Concurrency: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        func begin() { lock.withLock { active += 1; peak = max(peak, active) } }
        func end() { lock.withLock { active -= 1 } }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testOptionalDecoderConcurrencyBaseline() async throws {
        guard ProcessInfo.processInfo.environment["WALLMOTION_THUMBNAIL_STRESS"] == "1" else {
            throw XCTSkip("Set WALLMOTION_THUMBNAIL_STRESS=1 for controlled thumbnail decode stress")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionThumbnailStress-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [NSColor.systemBlue.cgColor, NSColor.systemOrange.cgColor, NSColor.systemPurple.cgColor] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 2048, y: 1024), options: [])
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        _ = try XCTUnwrap(MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: 440, targetHeight: 236))
        let concurrency = Concurrency()
        let cpuStart = cpuSeconds()
        let start = ContinuousClock.now
        let completed = try await withThrowingTaskGroup(of: Int.self, returning: Int.self) { group in
            for index in 0..<48 {
                group.addTask {
                    try await Task.detached(priority: .utility) {
                        concurrency.begin()
                        defer { concurrency.end() }
                        return try autoreleasepool {
                            guard let image = MediaThumbnailDecoding.imageThumbnail(url: url, targetWidth: 400 + index, targetHeight: 236),
                                  ThumbnailBudget.cost(of: image) != nil else { throw CocoaError(.fileReadCorruptFile) }
                            return 1
                        }
                    }.value
                }
            }
            var count = 0
            for try await value in group { count += value }
            return count
        }
        let duration = start.duration(to: .now)
        print("THUMBNAIL_STRESS baseline requests=48 completed=\(completed) peak_active=\(concurrency.peak) elapsed=\(duration) process_cpu_ms=\((cpuSeconds() - cpuStart) * 1000)")
        XCTAssertEqual(completed, 48)
        XCTAssertGreaterThan(concurrency.peak, 0)
    }
}
