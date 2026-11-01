import XCTest
@testable import ISeeYou

final class HumanTeacherCorrectionTests: XCTestCase {
    func testCorrectionJSONIncludesHumanAndModelObservations() throws {
        let id = UUID(uuidString: "D68C7BB8-93D2-4E88-927D-970B9D9F3450")!
        let box = HumanTeacherCorrection.BoundingBox(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        let detection = HumanTeacherCorrection.OriginalDetection(
            label: "laptop", confidence: 0.95, boundingBox: box)
        let correction = HumanTeacherCorrection(
            id: id, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptText: "Correction, this is a piano",
            originalDetection: detection, modelVersion: "yolo11n-v1",
            frameObjectKey: "corrections/\(id.uuidString.lowercased())/frame.jpg")
        let data = try correction.encodedJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HumanTeacherCorrection.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.transcriptText, "Correction, this is a piano")
        XCTAssertEqual(decoded.originalDetection?.label, "laptop")
        XCTAssertEqual(decoded.originalDetection?.boundingBox.width, 0.4)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.frameObjectKey, correction.s3Prefix + "frame.jpg")
        XCTAssertNil(decoded.clipObjectKey)
    }

    func testMissedDetectionCanBeRecordedWithoutOriginalBoundingBox() throws {
        let correction = HumanTeacherCorrection(
            transcriptText: "Correction, you missed a bollard",
            originalDetection: nil, modelVersion: "yolo11n-v1",
            frameObjectKey: "corrections/test/frame.jpg")
        let data = try correction.encodedJSON()
        XCTAssertNotNil(String(data: data, encoding: .utf8))
        XCTAssertTrue(correction.s3Prefix.hasPrefix("corrections/"))
    }
}
