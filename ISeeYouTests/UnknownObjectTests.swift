import XCTest
@testable import ISeeYou

final class UnknownObjectTests: XCTestCase {
    private func item(_ confidence: Float, label: String = "laptop") -> Detection {
        Detection(label: label, confidence: confidence,
            bounds: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.6),
            distance: ObjectDistance(metres: 1.3, spread: 0.1, coverage: 1))
    }
    func testFiftyPercentBoundaryPreservesGeometryAndDistance() {
        let low = item(0.499).conservativelyNamed()
        XCTAssertEqual(low.label, "unknown object")
        XCTAssertEqual(low.distance?.metres, 1.3)
        XCTAssertEqual(low.bounds, item(0.499).bounds)
        XCTAssertEqual(low.confidence, 0.499)
        XCTAssertEqual(item(0.5).conservativelyNamed().label, "laptop")
        XCTAssertEqual(item(0.99).conservativelyNamed().label, "laptop")
    }
    func testSpeechUsesUnknownAcrossChangingLowConfidenceClasses() {
        final class Speech: SpeechAlerting {
            var spoken: [SpokenAlert] = []
            func speak(_ alert: SpokenAlert) { spoken.append(alert) }
            func cancel() {}
        }
        for scale: Double? in [nil, 1] {
            let speech = Speech()
            let controller = HazardAlertController(speech: speech)
            for tick in 0...5 {
                controller.preview([item(0.45, label: tick % 2 == 0 ? "laptop" : "couch")],
                    at: Double(tick) * 0.2, distanceScale: scale)
            }
            XCTAssertEqual(speech.spoken.count, 1)
            XCTAssertTrue(speech.spoken[0].message.hasPrefix("unknown object"))
            XCTAssertFalse(speech.spoken[0].message.contains("laptop"))
        }
    }
    func testBelowDetectionFloorDoesNotSpeak() {
        final class Speech: SpeechAlerting {
            var count = 0
            func speak(_ alert: SpokenAlert) { count += 1 }
            func cancel() {}
        }
        let speech = Speech(); let controller = HazardAlertController(speech: speech)
        for tick in 0...5 { controller.preview([item(0.3)], at: Double(tick) * 0.2) }
        XCTAssertEqual(speech.count, 0)
    }
}
