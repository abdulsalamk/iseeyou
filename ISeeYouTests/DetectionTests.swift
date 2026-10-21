import XCTest
import AVFoundation
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


final class HazardAssessmentTests: XCTestCase {
    private let assessor = HazardAssessment()
    private func object(_ label: String = "teddy bear", x: CGFloat = 0.4,
                        y: CGFloat = 0.05, width: CGFloat = 0.2,
                        height: CGFloat = 0.2) -> Detection {
        Detection(label: label, confidence: 0.9,
                  bounds: CGRect(x: x, y: y, width: width, height: height))
    }
    private func evaluate(_ d: Detection, contact: GroundContact = .floor,
                          motion: UserMotion = .walking, stable: Bool = true,
                          imminent: Bool = false) -> HazardDecision {
        var context = HazardContext()
        context.poseStable = stable
        context.motion = motion
        context.contact[d.id] = contact
        if imminent { context.imminent.insert(d.id) }
        return assessor.assess([d], context: context, sensitivity: .conservative)[0]
    }
    func testSameTeddyOnSofaAndFloor() {
        let teddy = object()
        XCTAssertEqual(evaluate(teddy, contact: .supported).level, .silence)
        XCTAssertEqual(evaluate(teddy).level, .caution)
        XCTAssertEqual(evaluate(teddy).message, "Trip hazard ahead")
    }
    func testSideChairAndBlockingChair() {
        XCTAssertEqual(evaluate(object("chair", x: 0.01, width: 0.1, height: 0.5)).level, .silence)
        XCTAssertEqual(evaluate(object("chair", height: 0.5)).level, .caution)
    }
    func testWallRequiresAdditionalDetectorAndInteractionEvidence() {
        // Synthetic wall from a hypothetical validated provider; COCO has no wall label.
        let wall = object("wall", x: 0.1, width: 0.8, height: 0.8)
        XCTAssertEqual(evaluate(wall, imminent: true).level, .urgent)
        XCTAssertEqual(evaluate(wall, contact: .unknown).level, .silence)
    }
    func testUnknownDepthContactOcclusionMotionAndPoseAbstain() {
        let d = object()
        for contact in [GroundContact.unknown, .occluded, .supported] {
            XCTAssertEqual(evaluate(d, contact: contact).level, .silence)
        }
        XCTAssertEqual(evaluate(d, motion: .stationary).level, .silence)
        XCTAssertEqual(evaluate(d, motion: .unknown).level, .silence)
        XCTAssertEqual(evaluate(d, stable: false).level, .silence)
        XCTAssertEqual(assessor.assess([d], context: HazardContext(), sensitivity: .balanced)[0].level, .silence)
    }
    func testHighFootSmallAndLowConfidenceSuppressed() {
        XCTAssertEqual(evaluate(object(y: 0.6)).level, .silence)
        XCTAssertEqual(evaluate(object(width: 0.02, height: 0.03)).level, .silence)
        let low = Detection(label: "chair", confidence: 0.7, bounds: object().bounds)
        XCTAssertEqual(assessor.assess([low], context: HazardContext(), sensitivity: .conservative)[0].rationale, "Low confidence")
    }
    func testUnavailableSurfaceCapabilitiesAreEmpty() {
        XCTAssertTrue(UnavailableSurfaceHazards().validatedCapabilities.isEmpty)
        XCTAssertTrue(UnavailableSurfaceHazards().hazards(at: 0).isEmpty)
    }
}

final class AlertPolicyTests: XCTestCase {
    private func decision(_ level: AlertLevel = .caution, x: CGFloat = 0.4) -> HazardDecision {
        HazardDecision(detection: Detection(label: "chair", confidence: 0.9,
                        bounds: CGRect(x: x, y: 0.05, width: 0.2, height: 0.5)),
                       level: level, rationale: "Synthetic validated evidence",
                       message: level == .urgent ? "Obstacle ahead, stop" : "Obstacle ahead")
    }
    func testConfirmationJitterCooldownAndRepeat() {
        var p = AlertPolicy()
        for tick in 0..<7 {
            XCTAssertNil(p.update([decision(x: tick % 2 == 0 ? 0.4 : 0.41)], at: Double(tick) * 0.1))
        }
        XCTAssertEqual(p.update([decision()], at: 0.8)?.level, .caution)
        for tick in 9..<88 { XCTAssertNil(p.update([decision()], at: Double(tick) * 0.1)) }
        XCTAssertEqual(p.update([decision()], at: 8.9)?.level, .caution)
    }
    func testSingleFrameAndOffPathNeverConfirm() {
        var p = AlertPolicy()
        XCTAssertNil(p.update([decision()], at: 0))
        XCTAssertNil(p.update([], at: 0.1))
        XCTAssertNil(p.update([decision()], at: 0.2))
        XCTAssertNil(p.update([], at: 0.3))
        XCTAssertNil(p.update([decision(.silence)], at: 0.4))
    }
    func testOcclusionAndDroppedFramesRequireNewConfirmation() {
        var p = AlertPolicy()
        XCTAssertNil(p.update([decision()], at: 0))
        XCTAssertNil(p.update([decision()], at: 0.3))
        XCTAssertNil(p.update([decision(.silence)], at: 0.4))
        XCTAssertNil(p.update([decision()], at: 0.5))
        XCTAssertNil(p.update([decision()], at: 2))
        XCTAssertNil(p.update([decision()], at: 2.1))
    }
    func testUrgentEscalatesAfterConfirmationInsideCooldown() {
        var p = AlertPolicy()
        for tick in 0..<7 { _ = p.update([decision()], at: Double(tick) * 0.1) }
        XCTAssertNotNil(p.update([decision()], at: 0.8))
        XCTAssertNil(p.update([decision(.urgent)], at: 1))
        XCTAssertNil(p.update([decision(.urgent)], at: 1.1))
        XCTAssertEqual(p.update([decision(.urgent)], at: 1.3)?.level, .urgent)
        XCTAssertNil(p.update([decision(.urgent)], at: 1.4))
    }
    func testResetAndClockRegressionDropHistory() {
        var p = AlertPolicy()
        _ = p.update([decision()], at: 1)
        _ = p.update([decision()], at: 1.3)
        p.reset()
        XCTAssertNil(p.update([decision()], at: 1.4))
        XCTAssertNil(p.update([decision()], at: 0))
    }
}

private final class SpySpeech: SpeechAlerting {
    var alerts: [SpokenAlert] = []
    var cancellations = 0
    func speak(_ alert: SpokenAlert) { alerts.append(alert) }
    func cancel() { cancellations += 1 }
}

final class HazardLifecycleTests: XCTestCase {
    func testObjectVoicePreviewConfirmsAndDescribesWithoutHazardClaim() {
        let speech = SpySpeech()
        let controller = HazardAlertController(speech: speech)
        for tick in 0...8 {
            controller.preview([Detection(label: "chair", confidence: 0.9,
                bounds: CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.5))], at: Double(tick) * 0.1)
        }
        XCTAssertEqual(speech.alerts.count, 1)
        XCTAssertEqual(speech.alerts.first?.message, "chair in front of the camera")
        controller.reset()
        XCTAssertEqual(speech.cancellations, 1)
    }
    func testVoiceButtonUsesInjectedSpeechService() {
        let speech = SpySpeech()
        let controller = HazardAlertController(speech: speech)
        controller.testVoice()
        XCTAssertEqual(speech.alerts.count, 1)
        XCTAssertTrue(speech.alerts[0].message.contains("Voice is working"))
    }

    func testAudioInterruptionCancelsPendingState() {
        let speech = SpySpeech()
        let controller = HazardAlertController(speech: speech)
        let send = {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                object: nil, userInfo: [AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue])
        }
        if Thread.isMainThread { send() } else { DispatchQueue.main.sync(execute: send) }
        XCTAssertEqual(speech.cancellations, 1)
        controller.update([], at: 1, enabled: true)
        XCTAssertTrue(speech.alerts.isEmpty)
    }

    func testStopBackgroundAndSpeechOffCancelAndClearConfirmation() {
        let speech = SpySpeech()
        let controller = HazardAlertController(speech: speech)
        let d = HazardDecision(detection: Detection(label: "chair", confidence: 0.9,
                    bounds: CGRect(x: 0.4, y: 0.05, width: 0.2, height: 0.5)),
                    level: .caution, rationale: "Synthetic", message: "Obstacle ahead")
        controller.update([d], at: 0, enabled: true)
        controller.update([d], at: 0.3, enabled: true)
        controller.reset() // same operation called by stop/background
        controller.update([d], at: 0.4, enabled: true)
        XCTAssertTrue(speech.alerts.isEmpty)
        controller.update([d], at: 0.6, enabled: false)
        XCTAssertEqual(speech.cancellations, 2)
        controller.update([d], at: 0.7, enabled: true)
        XCTAssertTrue(speech.alerts.isEmpty)
    }
}
