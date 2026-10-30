import AppKit
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class ThermalPolicyModelTests: XCTestCase {
    private final class PressureSource {
        var value: ThermalPausePolicy.Pressure = .nominal
    }

    func testNotificationsHysteresisAndManualIntentSurviveRecovery() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let source = PressureSource()
        let model = LibraryModel(thermalState: { source.value }, store: store, connectedDisplays: { [] })
        model.setPauseOnLowPower(false)
        model.start()
        defer { model.stop() }
        XCTAssertFalse(model.isPaused)
        source.value = .serious
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.playbackDescription, "Pausado · pressão térmica")
        XCTAssertEqual(model.manualPauseActionTitle, "Manter pausado")
        model.togglePause()
        XCTAssertEqual(model.manualPauseActionTitle, "Liberar pausa manual")
        source.value = .fair
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        model.togglePause()
        XCTAssertTrue(model.isPaused)
        model.togglePause()
        source.value = .nominal
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.playbackDescription, "Pausado por você")
        XCTAssertEqual(model.manualPauseActionTitle, "Retomar")
        model.togglePause()
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.manualPauseActionTitle, "Pausar")
        XCTAssertFalse(try store.load().settings.isManuallyPaused)
    }

    func testInitialPressureOptOutPersistsAndStopRemovesObserver() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let source = PressureSource()
        source.value = .critical
        let model = LibraryModel(thermalState: { source.value }, store: store, connectedDisplays: { [] })
        model.setPauseOnLowPower(false)
        XCTAssertTrue(model.isPaused)
        model.start()
        model.setPauseOnThermalPressure(false)
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(try store.load().settings.pauseOnThermalPressure)
        let restored = LibraryModel(thermalState: { source.value }, store: store, connectedDisplays: { [] })
        XCTAssertFalse(restored.isPaused)
        restored.stop()
        model.setPauseOnThermalPressure(true)
        XCTAssertTrue(model.isPaused)
        model.stop()
        source.value = .nominal
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertTrue(model.isPaused) // Stopped model no longer observes notifications.
        model.start()
        XCTAssertFalse(model.isPaused) // Restart re-reads the live signal.
        model.stop()
    }
}
