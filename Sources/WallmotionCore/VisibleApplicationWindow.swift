import Foundation

/// Geometry and visibility only. No window titles or owner names are collected.
public struct VisibleApplicationWindow: Sendable {
    public let ownerPID: Int32
    public let layer: Int
    public let alpha: Double
    public let bounds: CGRect
    public let isOnscreen: Bool

    public init(ownerPID: Int32, layer: Int, alpha: Double, bounds: CGRect, isOnscreen: Bool = true) {
        self.ownerPID = ownerPID; self.layer = layer; self.alpha = alpha
        self.bounds = bounds; self.isOnscreen = isOnscreen
    }

    public static func occupiedDisplays(windows: [Self]?, displayBounds: [String: CGRect], ownPID: Int32,
                                        regularApplicationPIDs: Set<Int32>) -> Set<String> {
        // A failed metadata query removes only this optional pause reason.
        guard let windows else { return [] }
        var occupied = Set<String>()
        for window in windows where window.isOnscreen && window.ownerPID > 0 && window.ownerPID != ownPID &&
            regularApplicationPIDs.contains(window.ownerPID) &&
            window.layer == 0 && window.alpha.isFinite && window.alpha > 0 && valid(window.bounds) {
            for (id, frame) in displayBounds where !occupied.contains(id) && valid(frame) {
                let intersection = frame.intersection(window.bounds)
                if !intersection.isNull && intersection.width > 0 && intersection.height > 0 { occupied.insert(id) }
            }
        }
        return occupied
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite) &&
            !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
    }
}
