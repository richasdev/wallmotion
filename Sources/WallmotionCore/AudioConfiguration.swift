import Foundation

/// Small immutable preferences snapshot for pending renderer work. Contains no
/// catalog or media buffers; invalid numbers fail closed at the playback edge.
public struct AudioConfiguration: Equatable, Sendable {
    public let displayID: String?
    public let masterVolume: Double
    public let gains: [String: Double]

    public init(displayID: String? = nil, masterVolume: Double = 1, gains: [String: Double] = [:]) {
        self.displayID = displayID;self.masterVolume = masterVolume;self.gains = gains
    }
    public func effectiveVolume(for wallpaperID: UUID) -> Double {
        let gain = gains[wallpaperID.uuidString] ?? 1
        guard gain.isFinite, masterVolume.isFinite, (0...1).contains(gain), (0...1).contains(masterVolume) else { return 0 }
        return masterVolume * gain
    }
}
