import XCTest
import CoreVideo
@testable import ISeeYou

final class DoorSceneTests: XCTestCase {
    @MainActor
    func testStoppedCameraGivesActionableDoorMessageThatSurvivesStop() {
        let engine = CameraEngine()
        engine.checkDoorState()
        XCTAssertFalse(engine.doorChecking)
        XCTAssertEqual(engine.doorStatus, "Start the camera before checking a door.")
        engine.stop(reason: "App entered background")
        XCTAssertEqual(engine.doorStatus, "Start the camera before checking a door.")
    }
    func testStateRequiresDoorAndStateSeparation() {
        XCTAssertEqual(DoorSceneScoring.decide(["closed": 0.4, "open": 0.28, "partlyOpen": 0.29, "wall": 0.25]), .closed)
        XCTAssertEqual(DoorSceneScoring.decide(["closed": 0.27, "open": 0.4, "partlyOpen": 0.28, "wall": 0.24]), .open)
        XCTAssertEqual(DoorSceneScoring.decide(["closed": 0.27, "open": 0.28, "partlyOpen": 0.4, "wall": 0.24]), .partlyOpen)
    }
    func testAmbiguityAndNonDoorScenesAbstain() {
        for scores in [
            ["closed": 0.35, "open": 0.25, "partlyOpen": 0.2, "wall": 0.4],
            ["closed": 0.15, "open": 0.1, "partlyOpen": 0.1, "wall": 0.05],
            ["closed": Double.nan, "open": 0.4, "partlyOpen": 0.2, "wall": 0.1],
            ["open": 0.9],
        ] { XCTAssertEqual(DoorSceneScoring.decide(scores), .uncertain) }
    }
    func testDoorPresenceDoesNotInventAStateWhenStatesAreClose() {
        XCTAssertEqual(DoorSceneScoring.decide(["closed": 0.35, "open": 0.34, "partlyOpen": 0.3, "wall": 0.2]), .stateUncertain)
        XCTAssertEqual(DoorSceneScoring.decide(["closed": 0.35, "open": 0.34, "partlyOpen": 0.3, "wall": 0.34]), .uncertain)
        XCTAssertEqual(DoorVisualState.stateUncertain.message, "Possible door. Open or closed uncertain.")
        var consensus = DoorStateConsensus()
        XCTAssertNil(consensus.update(.stateUncertain, at: 0))
        XCTAssertNil(consensus.update(.stateUncertain, at: 0.4))
        XCTAssertEqual(consensus.update(.stateUncertain, at: 0.8), .stateUncertain)
    }
    func testConsensusRequiresRepeatedFreshConsistentObservations() {
        var consensus = DoorStateConsensus()
        XCTAssertNil(consensus.update(.open, at: 0))
        XCTAssertNil(consensus.update(.open, at: 0.4))
        XCTAssertEqual(consensus.update(.open, at: 0.8), .open)
        XCTAssertNil(consensus.update(.closed, at: 1.2))
        XCTAssertNil(consensus.update(.closed, at: 3))
        XCTAssertNil(consensus.update(.closed, at: 3.4))
        XCTAssertEqual(consensus.update(.closed, at: 3.8), .closed)
    }
    func testExplicitDoorSpeechIsTentativeAndUnknownIsNotOpen() {
        final class Speech: SpeechAlerting {
            var messages: [String] = []
            func speak(_ alert: SpokenAlert) { messages.append(alert.message) }
            func cancel() {}
        }
        let speech = Speech()
        let controller = HazardAlertController(speech: speech)
        controller.speakDoorAssessment(.open)
        controller.speakDoorAssessment(.uncertain)
        XCTAssertEqual(speech.messages, ["Door may be open. Opening not verified.", "Door not established. State uncertain."])
    }
    func testBundledDoorModelRunsAndBlankImagesDoNotBecomeDoors() throws {
        let classifier = try DoorSceneClassifier()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        for colour: Int32 in [0, 128, 255] {
            CVPixelBufferLockBaseAddress(image, [])
            memset(CVPixelBufferGetBaseAddress(image), colour, CVPixelBufferGetDataSize(image))
            CVPixelBufferUnlockBaseAddress(image, [])
            XCTAssertEqual(try classifier.assess(image), .uncertain)
        }
    }
}
