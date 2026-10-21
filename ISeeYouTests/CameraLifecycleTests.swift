import XCTest
@testable import ISeeYou

final class CameraLifecycleTests: XCTestCase {
    func testPermissionAlertDoesNotCancelStartButBackgroundDoes() {
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: true))
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: true))
    }
    func testRegularInactivityStopsCamera() {
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: false))
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: true, background: false, permissionPending: false))
    }
}
