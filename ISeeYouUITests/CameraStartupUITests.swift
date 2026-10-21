import XCTest

final class CameraStartupUITests: XCTestCase {
    func testStartStopAndRestartReceivesCameraFrames() {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.buttons["cameraToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Start camera")
        let frames = app.staticTexts["cameraFrames"]
        XCTAssertEqual(frames.label, "Received video frames: 0")
        toggle.tap()
        let receiving = NSPredicate { _, _ in
            let count = Int(frames.label.components(separatedBy: ": ").last ?? "0") ?? 0
            return count > 0
        }
        expectation(for: receiving, evaluatedWith: frames)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(toggle.label, "Stop camera")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["cameraStatus"].label.contains("Camera stopped"))
        toggle.tap()
        expectation(for: receiving, evaluatedWith: frames)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(toggle.label, "Stop camera")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Start camera", "Foreground return must not restart capture")
    }
}
