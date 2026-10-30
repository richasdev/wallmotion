import AppKit

/// A prepared image survives size changes, but must never leak into another card.
@MainActor
struct ThumbnailPresentation {
    private(set) var image: NSImage?
    private var request: ThumbnailRequest?

    mutating func begin(_ next: ThumbnailRequest) {
        if next.url == nil || request?.url != next.url || request?.kind != next.kind {
            image = nil
        }
        request = next
    }

    mutating func publish(_ image: NSImage, for completed: ThumbnailRequest) {
        guard completed == request, completed.url != nil else { return }
        self.image = image
    }
}
