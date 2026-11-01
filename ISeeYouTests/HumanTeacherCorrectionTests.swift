import XCTest
import CryptoKit
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

final class CorrectionWorkflowTests: XCTestCase {
    func testCommandParsing() {
        XCTAssertEqual(CorrectionCommand.label("Correction, this is a piano."), "piano")
        XCTAssertEqual(CorrectionCommand.label("Correction this is an umbrella"), "umbrella")
        XCTAssertEqual(CorrectionCommand.label("Correction. This is a piano!"), "piano")
        XCTAssertNil(CorrectionCommand.label("There is a piano"))
        XCTAssertNil(CorrectionCommand.label("Correction this is a"))
        XCTAssertNil(CorrectionCommand.label("Correction this is 123"))
    }
    func testAssociationNeverGuessesAmongObjects() {
        let item = Detection(label: "laptop", confidence: 0.9, bounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertNil(CorrectionCommand.association([]))
        XCTAssertNil(CorrectionCommand.association([item, item]))
        XCTAssertEqual(CorrectionCommand.association([item])?.id, item.id)
    }
    func testRetryRequiresAppIdleAndUsesBackoff() {
        let now = Date(); var retry = CorrectionRetry()
        XCTAssertFalse(retry.ready(now: now, idle: false))
        XCTAssertTrue(retry.ready(now: now, idle: true))
        retry.failed(now: now)
        XCTAssertFalse(retry.ready(now: now, idle: true))
        XCTAssertTrue(retry.ready(now: now.addingTimeInterval(31), idle: true))
        for _ in 0..<8 { retry.failed(now: now) }
        XCTAssertFalse(retry.ready(now: now.addingTimeInterval(10000), idle: true))
    }
    func testCaptureQueuesMatchingFrameAndMetadataOffCallerQueue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let teacher = HumanTeacher(directory: directory)
        let done = expectation(description: "Capture persisted")
        teacher.captureFixtureForTest { done.fulfill() }
        wait(for: [done], timeout: 5)
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let folder = try XCTUnwrap(folders.first)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(HumanTeacherCorrection.self, from: Data(contentsOf: folder.appendingPathComponent("correction.json")))
        XCTAssertEqual(record.correctedLabel, "piano")
        XCTAssertEqual(record.originalDetection?.label, "laptop")
        XCTAssertEqual(record.id.uuidString.lowercased(), folder.lastPathComponent)
        XCTAssertEqual(record.frameObjectKey, record.s3Prefix + "frame.jpg")
        let jpeg = try Data(contentsOf: folder.appendingPathComponent("frame.jpg"))
        XCTAssertEqual(record.frameSHA256, SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(record.processingState, "awaiting_validation")
    }
}
