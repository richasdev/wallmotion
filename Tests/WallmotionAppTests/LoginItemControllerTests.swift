import XCTest
@testable import Wallmotion

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testInitialStateComesFromServiceAndDoesNotRegister() {
        let service = FakeLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testRegisterReflectsApprovalRequiredState() {
        let service = FakeLoginItemService(status: .notRegistered, nextStatus: .requiresApproval)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.status.isEnabled)
    }

    func testUnregisterReflectsDisabledState() {
        let service = FakeLoginItemService(status: .enabled, nextStatus: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.status.isEnabled)
    }

    func testRegistrationFailureKeepsServiceStatusAndReportsError() {
        let service = FakeLoginItemService(status: .notRegistered, failure: TestError.failed)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNotNil(controller.errorMessage)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    private(set) var status: LoginItemStatus
    private let nextStatus: LoginItemStatus?
    private let failure: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LoginItemStatus, nextStatus: LoginItemStatus? = nil, failure: Error? = nil) {
        self.status = status
        self.nextStatus = nextStatus
        self.failure = failure
    }

    func register() throws {
        registerCount += 1
        if let failure { throw failure }
        if let nextStatus { status = nextStatus }
    }

    func unregister() throws {
        unregisterCount += 1
        if let failure { throw failure }
        if let nextStatus { status = nextStatus }
    }
}

private enum TestError: Error { case failed }
