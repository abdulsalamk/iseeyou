import XCTest
@testable import ISeeYou

final class DetectionTests: XCTestCase {
    func testPathOverlapIncludesObjectsStraddlingBoundary() {
        XCTAssertTrue(Detection(label: "chair", confidence: 0.9, bounds: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.5)).inPath)
        XCTAssertFalse(Detection(label: "person", confidence: 0.9, bounds: CGRect(x: 0, y: 0, width: 0.3, height: 1)).inPath)
        XCTAssertFalse(Detection(label: "car", confidence: 0.9, bounds: CGRect(x: 0.7, y: 0, width: 0.2, height: 1)).inPath)
    }
    func testVisionBottomLeftCoordinatesConvertToPortraitPreview() {
        let rect = DetectionGeometry.displayRect(CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6), in: CGSize(width: 100, height: 200))
        XCTAssertEqual(rect.minX, 25, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 40, accuracy: 0.001)
        XCTAssertEqual(rect.height, 120, accuracy: 0.001)
    }
}
