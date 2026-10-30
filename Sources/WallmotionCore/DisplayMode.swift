public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case independent, mirrored, spanned

    public var isShared: Bool { self != .independent }
}
