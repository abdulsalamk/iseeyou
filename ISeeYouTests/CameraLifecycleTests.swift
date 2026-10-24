import XCTest
import AVFoundation
@testable import ISeeYou

final class CameraLifecycleTests: XCTestCase {
    func testExplicitGlassesSessionSurvivesLockAndAppSwitch() {
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: false, glassesSessionRequested: true))
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: false, glassesSessionRequested: true))
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: false, glassesSessionRequested: false))
    }
    func testPermissionAlertDoesNotCancelStartButBackgroundDoes() {
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: true))
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: true, permissionPending: true))
    }
    func testRegularInactivityStopsCamera() {
        XCTAssertTrue(CameraLifecyclePolicy.shouldStop(active: false, background: false, permissionPending: false))
        XCTAssertFalse(CameraLifecyclePolicy.shouldStop(active: true, background: false, permissionPending: false))
    }
    func testTeacherEncodesSilentThreeFrameClipOnDevice() async throws {
        let teacher = BackgroundTeacher()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try teacher.encodeSyntheticClipForTest(to: url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        var timestamps: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil {
                count += 1
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(count, 3)
        for expected in [0.0, 1.0, 2.0] {
            XCTAssertTrue(timestamps.contains { abs($0 - expected) < 0.1 })
        }
        XCTAssertTrue(timestamps.allSatisfy { $0 >= 0 && $0 < 3 })
        XCTAssertFalse(teacher.enabled)
    }
}
