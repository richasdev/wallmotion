import Foundation

/// Desired maximum dimensions for native HLS variant selection, not a strict cap.
public enum HLSResolution: String, Codable, CaseIterable, Sendable {
    case automatic, hd720, fullHD1080, uhd2160

    public var maximumDimensions: (width: Int, height: Int)? {
        switch self {
        case .automatic: nil
        case .hd720: (1280, 720)
        case .fullHD1080: (1920, 1080)
        case .uhd2160: (3840, 2160)
        }
    }
}
