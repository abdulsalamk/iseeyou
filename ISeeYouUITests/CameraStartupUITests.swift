import XCTest

final class CameraStartupUITests: XCTestCase {
    func testStartStopAndRestartReceivesCameraFrames() {
        let app = XCUIApplication()
        app.launch()
        let toggle = app.buttons["cameraToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let frames = app.staticTexts["cameraFrames"]
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
        toggle.tap()
    }
}
