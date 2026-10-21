import XCTest
@testable import ISeeYou

final class CameraLifecycleTests: XCTestCase {
    func testExplicitGlassesSessionSurvivesLockAndAppSwitch() {
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: false, glassesSessionRequested: true))
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: false, glassesSessionRequested: true))
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: false, glassesSessionRequested: false))
    }
    func testPermissionAlertDoesNotCancelStartButBackgroundDoes() {
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: true))
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: true))
    }
    func testRegularInactivityStopsCamera() {
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: false))
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: true, background: false, permissionPending: false))
    }
}
