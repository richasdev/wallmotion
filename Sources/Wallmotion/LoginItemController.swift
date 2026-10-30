import AppKit
import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable

    var isEnabled: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class MainAppLoginItemService: LoginItemServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) { self.service = service }

    var status: LoginItemStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
@Observable
final class LoginItemController {
    private let service: any LoginItemServicing
    private(set) var status: LoginItemStatus
    private(set) var errorMessage: String?

    init(service: any LoginItemServicing = MainAppLoginItemService()) {
        self.service = service
        self.status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled { try service.register() } else { try service.unregister() }
            status = service.status
        } catch {
            status = service.status
            errorMessage = "Não foi possível atualizar o início automático: \(error.localizedDescription)"
        }
    }

    func refreshStatus() { status = service.status }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
