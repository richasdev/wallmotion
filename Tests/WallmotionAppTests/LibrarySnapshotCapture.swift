import AppKit
import QuartzCore

@MainActor
enum LibrarySnapshotCapture {
    enum Failure: LocalizedError {
        case invalidBounds, noRenderedContent
        var errorDescription: String? {
            switch self {
            case .invalidBounds: "A view de snapshot tem dimensões inválidas."
            case .noRenderedContent: "A captura permaneceu indisponível ou sem a variação de cores esperada até o prazo de QA."
            }
        }
    }

    static func capture(_ view: NSView) async throws -> NSBitmapImageRep {
        guard view.bounds.width.isFinite, view.bounds.height.isFinite,
              view.bounds.width > 0, view.bounds.height > 0 else { throw Failure.invalidBounds }
        return try await waitForContent {
            autoreleasepool {
                view.layoutSubtreeIfNeeded()
                view.window?.displayIfNeeded()
                view.layer?.displayIfNeeded()
                CATransaction.flush()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }
        }
    }

    static func waitForContent(timeout: Duration = .seconds(3), interval: Duration = .milliseconds(50),
                               capture: @MainActor () throws -> NSBitmapImageRep?) async throws -> NSBitmapImageRep {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            if let bitmap = try capture() {
                let ready = autoreleasepool { hasContent(bitmap) }
                if ready { return bitmap }
            }
            guard ContinuousClock.now < deadline else { throw Failure.noRenderedContent }
            // Yield MainActor so AppKit/SwiftUI can process their own updates.
            // The deadline bounds retries, not an uninterruptible native draw.
            try await Task.sleep(for: interval)
        }
    }

    /// Require three sampled color groups, rejecting unavailable/transparent frames. Heterogeneity
    /// is necessary evidence, not proof of complete/correct UI rendering.
    static func hasContent(_ bitmap: NSBitmapImageRep) -> Bool {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
        var distinct: [SIMD4<Double>] = []
        for row in 0..<24 {
            let y = (bitmap.pixelsHigh - 1) * row / 23
            for column in 0..<32 {
                let x = (bitmap.pixelsWide - 1) * column / 31
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                let value = SIMD4(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
                guard (0..<4).allSatisfy({ value[$0].isFinite }) else { continue }
                let close = distinct.contains { old in
                    (0..<4).allSatisfy { abs(old[$0] - value[$0]) < 0.03 }
                }
                if !close {
                    distinct.append(value)
                    if distinct.count >= 3 { return true }
                }
            }
        }
        return false
    }
}
