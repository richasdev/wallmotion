import Foundation
import Observation
import AppKit
import WallmotionCore

@MainActor @Observable
final class ApplicationSession {
    enum Phase: Equatable { case preparing, primary, busy, failed }
    let rootURL: URL
    private(set) var phase = Phase.preparing
    private(set) var model: LibraryModel?
    private(set) var errorMessage: String?
    @ObservationIgnored private var lease: LibraryProcessLock?
    @ObservationIgnored private var finishedLaunching = false
    @ObservationIgnored private let acquire: @MainActor () throws -> LibraryProcessLock?
    @ObservationIgnored private let publish: @MainActor (LibraryProcessLock) throws -> Void
    @ObservationIgnored private let makeModel: @MainActor () -> LibraryModel

    init(store: LibraryStore = LibraryStore(),
         acquire: (@MainActor () throws -> LibraryProcessLock?)? = nil,
         publish: (@MainActor (LibraryProcessLock) throws -> Void)? = nil,
         makeModel: (@MainActor () -> LibraryModel)? = nil) {
        self.rootURL = store.rootURL
        self.acquire = acquire ?? { try LibraryProcessLock.acquire(in: store.rootURL) }
        self.publish = publish ?? { lease in
            try lease.publishIdentity(LibraryProcessIdentity(
                processID: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.richas.wallmotion",
                launchTime: NSRunningApplication.current.launchDate?.timeIntervalSince1970))
        }
        self.makeModel = makeModel ?? { LibraryModel(store: store) }
    }

    func prepare() {
        guard model == nil else { return }
        phase = .preparing
        errorMessage = nil
        do {
            guard let acquired = try acquire() else { phase = .busy; return }
            do { try publish(acquired) }
            catch { acquired.release(); throw error }
            lease = acquired
            model = makeModel()
            phase = .primary
            if finishedLaunching { model?.start() }
        } catch {
            phase = .failed
            errorMessage = "Não foi possível obter acesso exclusivo à biblioteca. Feche outras instâncias e verifique os arquivos de controle antes de tentar novamente."
        }
    }

    func finishLaunching() {
        guard !finishedLaunching else { return }
        finishedLaunching = true
        model?.start()
    }

    func stop() {
        model?.stop()
        // Retain the lease until this process/session ends. Pending import work
        // must not outlive ownership during application termination.
    }
}
