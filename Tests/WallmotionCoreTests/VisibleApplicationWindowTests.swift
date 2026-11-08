import XCTest
@testable import WallmotionCore

final class VisibleApplicationWindowTests: XCTestCase {
    private let displays = ["left": CGRect(x: -1000, y: 0, width: 1000, height: 800),
                            "right": CGRect(x: 0, y: -400, width: 1200, height: 900)]
    func testNormalWindowsOccupyOnlyIntersectedDisplaysIncludingNegativeAndVerticalCoordinates() {
        let left = VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: CGRect(x: -800, y: 100, width: 300, height: 200))
        XCTAssertEqual(VisibleApplicationWindow.occupiedDisplays(windows: [left], displayBounds: displays, ownPID: 1), ["left"])
        let across = VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 0.5, bounds: CGRect(x: -20, y: 10, width: 100, height: 200))
        XCTAssertEqual(VisibleApplicationWindow.occupiedDisplays(windows: [across], displayBounds: displays, ownPID: 1), ["left", "right"])
        let upper = VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: CGRect(x: 10, y: -300, width: 100, height: 200))
        XCTAssertEqual(VisibleApplicationWindow.occupiedDisplays(windows: [upper], displayBounds: displays, ownPID: 1), ["right"])
    }
    func testOwnHiddenTransparentDesktopMenusInvalidAndTouchingEdgeWindowsDoNotOccupyDisplay() {
        let bounds = CGRect(x: -100, y: 100, width: 50, height: 50)
        let ignored = [
            VisibleApplicationWindow(ownerPID: 1, layer: 0, alpha: 1, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: bounds, isOnscreen: false),
            VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 0, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: .nan, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 2, layer: -2147483623, alpha: 1, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 2, layer: 24, alpha: 1, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 0, layer: 0, alpha: 1, bounds: bounds),
            VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: .zero),
            VisibleApplicationWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: CGRect(x: -1100, y: 0, width: 100, height: 100))
        ]
        XCTAssertEqual(VisibleApplicationWindow.occupiedDisplays(windows: ignored, displayBounds: displays, ownPID: 1), [])
        XCTAssertEqual(VisibleApplicationWindow.occupiedDisplays(windows: nil, displayBounds: displays, ownPID: 1), [])
    }
    func testPreferenceDefaultsFalseForOldSettingsAndRoundTripsWithoutVersionChange() throws {
        let old = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.pauseWhenOtherAppsVisible)
        var state = LibraryState(); let version = state.version
        state.settings.pauseWhenOtherAppsVisible = true
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.settings.pauseWhenOtherAppsVisible)
        XCTAssertEqual(restored.version, version)
    }
}
