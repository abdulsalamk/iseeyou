import XCTest
import CoreVideo
@testable import ISeeYou

final class MetricDistanceTests: XCTestCase {
    func testSamplingMapsVisionTopObjectToTopDepthRows() {
        let result = DepthSampling.read(bounds: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.2), width: 100, height: 100) { _, y in y < 50 ? 1 : 5 }
        XCTAssertEqual(result?.metres, 1)
    }
    func testSamplingRejectsInvalidTinyAndMixedDepth() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertNil(DepthSampling.read(bounds: box, width: 100, height: 100) { _, _ in .nan })
        XCTAssertNil(DepthSampling.read(bounds: CGRect(x: 0, y: 0, width: 0.01, height: 0.01), width: 100, height: 100) { _, _ in 1 })
        XCTAssertNil(DepthSampling.read(bounds: box, width: 100, height: 100) { x, _ in x < 50 ? 1 : 5 })
    }
    private func trial(_ actual: Double, raw: Double, scale: Double = 1, validation: Bool) -> DistanceTrial {
        DistanceTrial(date: Date(), modelID: MetricDepthEstimator.modelID, label: "chair", actual: actual,
            raw: raw, scale: scale, latencyMS: 100, validation: validation)
    }
    func testCalibrationCannotPassWithTrainingOnlyOrMissingRange() {
        var profile = CalibrationProfile(trials: [0.5, 1, 2].map { trial($0, raw: $0 / 1.2, validation: false) })
        XCTAssertEqual(profile.scale ?? 0, 1.2, accuracy: 0.00001)
        XCTAssertFalse(profile.passed)
        for target in CalibrationProfile.targets {
            for _ in 0..<3 { profile.trials.append(trial(target, raw: target / 1.2, scale: 1.2, validation: true)) }
        }
        XCTAssertTrue(profile.passed)
        profile.trials.removeLast()
        XCTAssertFalse(profile.passed)
    }
    func testMeasuredReferenceScalesRatherThanSubtractingAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let calibration = DistanceCalibration(url: url)
        calibration.applyReference(actual: 2, reported: 3)
        XCTAssertEqual(try XCTUnwrap(calibration.profile.scale), 2.0/3, accuracy: 0.00001)
        XCTAssertFalse(calibration.profile.passed)
        XCTAssertEqual(try XCTUnwrap(DistanceCalibration(url: url).profile.scale) * 0.6, 0.4, accuracy: 0.00001)
        calibration.applyReference(actual: 0, reported: 3)
        XCTAssertEqual(try XCTUnwrap(calibration.profile.scale), 2.0/3, accuracy: 0.00001)
        calibration.reset()
        XCTAssertNil(calibration.profile.scale)
    }
    func testNearRangeFailureKeepsProfileUnvalidated() {
        var profile = CalibrationProfile(trials: [0.5, 1, 2].map { trial($0, raw: $0, validation: false) })
        for target in CalibrationProfile.targets {
            for _ in 0..<3 { profile.trials.append(trial(target, raw: target == 0.5 ? 0.7 : target, validation: true)) }
        }
        XCTAssertFalse(profile.passed)
    }
    func testDistanceSpeechRequiresDepthAndUsesMeasuredWording() {
        final class Speech: SpeechAlerting {
            var spoken: [SpokenAlert] = []
            func speak(_ alert: SpokenAlert) { spoken.append(alert) }
            func cancel() {}
        }
        let speech = Speech()
        let controller = HazardAlertController(speech: speech)
        var item = Detection(label: "chair", confidence: 0.99, bounds: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.6))
        for tick in 0...5 { controller.preview([item], at: Double(tick)*0.2, distanceScale: 1) }
        XCTAssertTrue(speech.spoken.isEmpty)
        item.distance = ObjectDistance(metres: 1.5, spread: 0.1, coverage: 1)
        for tick in 6...11 { controller.preview([item], at: Double(tick)*0.2, distanceScale: 1) }
        XCTAssertEqual(speech.spoken.first?.message, "chair, approximately 1.5 metres")
    }
    func testBundledDepthModelRunsOnPhysicalDevice() throws {
        let estimator = try MetricDepthEstimator()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 720, 1280, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<1280 { for x in 0..<720 {
            let i = y * stride + x * 4
            bytes[i] = UInt8(x % 256); bytes[i+1] = UInt8(y % 256); bytes[i+2] = 128; bytes[i+3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(image, [])
        let item = Detection(label: "test", confidence: 1, bounds: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let start = Date()
        for _ in 0..<3 {
            let results = try estimator.estimate(image, detections: [item])
            XCTAssertEqual(results.count, 1)
            if let depth = results[0].distance { XCTAssertTrue(depth.metres.isFinite) }
        }
        print("[ISeeYou.DepthTest] Three synthetic frame inferences in \(Date().timeIntervalSince(start)) seconds; not a distance-accuracy result")
    }
}
