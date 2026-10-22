import XCTest
@testable import ISeeYou

final class SurfaceDescriptionTests: XCTestCase {
    func testCentralUniformSurfaceNeedsNoObjectBox() throws {
        let reading = try XCTUnwrap(SurfaceDepthSampling.read(width: 294, height: 518) { _, _ in 1.5 })
        XCTAssertEqual(reading.metres, 1.5)
        XCTAssertEqual(reading.coverage, 1)
    }
    func testInvalidDistantMixedAndFloorLikeGradientAbstain() {
        XCTAssertNil(SurfaceDepthSampling.read(width: 294, height: 518) { _, _ in .nan })
        XCTAssertNil(SurfaceDepthSampling.read(width: 294, height: 518) { _, _ in 4 })
        XCTAssertNil(SurfaceDepthSampling.read(width: 294, height: 518) { x, _ in x < 147 ? 0.5 : 2 })
        XCTAssertNil(SurfaceDepthSampling.read(width: 294, height: 518) { _, y in 0.5 + Double(y) / 150 })
    }
    func testOffCentreNearDepthDoesNotBecomeCentralSurface() {
        XCTAssertNil(SurfaceDepthSampling.read(width: 294, height: 518) { x, _ in x < 80 ? 0.5 : 5 })
    }
    func testSurfaceSpeechRequiresPersistenceAndRespectsCooldownAndMissingDepth() {
        var policy = SurfaceAnnouncementPolicy()
        let reading = ObjectDistance(metres: 0.4, spread: 0.02, coverage: 1)
        for tick in 0..<5 { XCTAssertNil(policy.update(reading, at: Double(tick) * 0.2, scale: 1)) }
        XCTAssertEqual(policy.update(reading, at: 1, scale: 1)?.message, "Surface ahead, approximately 0.4 metres, very close")
        XCTAssertNil(policy.update(reading, at: 1.2, scale: 1))
        XCTAssertNil(policy.update(nil, at: 1.4, scale: 1))
        XCTAssertNil(policy.update(reading, at: 10, scale: 1))
        for tick in 1..<5 { XCTAssertNil(policy.update(reading, at: 10 + Double(tick) * 0.2, scale: 1)) }
        XCTAssertNotNil(policy.update(reading, at: 11, scale: 1))
    }
    func testDescriptionFallbackAndStopCancelConfirmation() {
        final class Speech: SpeechAlerting {
            var messages: [String] = []
            func speak(_ alert: SpokenAlert) { messages.append(alert.message) }
            func cancel() {}
        }
        let speech = Speech()
        let controller = HazardAlertController(speech: speech)
        let reading = ObjectDistance(metres: 1.5, spread: 0.05, coverage: 1)
        for tick in 0...5 { controller.preview([], at: Double(tick) * 0.2, surface: reading) }
        XCTAssertEqual(speech.messages, ["Surface ahead, approximately 1.5 metres"])
        controller.reset()
        controller.preview([], at: 10, surface: reading)
        XCTAssertEqual(speech.messages.count, 1)
        let chair = Detection(label: "chair", confidence: 0.9,
            bounds: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.6), distance: reading)
        for tick in 0...6 { controller.preview([chair], at: 11 + Double(tick) * 0.2, surface: reading) }
        XCTAssertEqual(speech.messages.last, "chair, approximately 1.5 metres")
        XCTAssertEqual(speech.messages.count, 2)
    }
}
