import XCTest
import CryptoKit
import Vision
import CoreML
@testable import ISeeYou

final class DetectorModelStoreTests: XCTestCase {
    func testSignedFilesAndTamperRejection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appendingPathComponent("candidate.mlpackage")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("Manifest.json")
        let bytes = Data("fixture".utf8); try bytes.write(to: file)
        let key = Curve25519.Signing.PrivateKey()
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let payload = DetectorModelStore.Payload(schema_version: 1, version: "test-1",
            files: [.init(path: "Manifest.json", size: bytes.count, sha256: hash)],
            evaluation_sha256: String(repeating: "a", count: 64), device_report_sha256: String(repeating: "b", count: 64))
        let data = try JSONEncoder().encode(payload)
        let envelope = try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": key.signature(for: data).base64EncodedString()])
        let store = DetectorModelStore(root: dir.appendingPathComponent("models"), documents: dir, publicKey: key.publicKey.rawRepresentation)
        XCTAssertEqual(try store.verifiedPayload(envelope: envelope, package: package).version, "test-1")
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try store.verifiedPayload(envelope: envelope, package: package))
        try bytes.write(to: file)
        let wrong = DetectorModelStore(root: dir, documents: dir, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        XCTAssertThrowsError(try wrong.verifiedPayload(envelope: envelope, package: package))
        try Data("extra".utf8).write(to: package.appendingPathComponent("unsigned"))
        XCTAssertThrowsError(try store.verifiedPayload(envelope: envelope, package: package))
    }
    func testTraversalAndSymlinkRejection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        let store = DetectorModelStore(root: dir, documents: dir, publicKey: key.publicKey.rawRepresentation)
        for path in ["../outside", "/absolute", "a/../b", "a//b"] {
            let payload = DetectorModelStore.Payload(schema_version: 1, version: "test", files: [.init(path: path, size: 1, sha256: "x")], evaluation_sha256: String(repeating: "a", count: 64), device_report_sha256: String(repeating: "b", count: 64))
            let bytes = try JSONEncoder().encode(payload)
            let envelope = try JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(), "signature": key.signature(for: bytes).base64EncodedString()])
            XCTAssertThrowsError(try store.verifiedPayload(envelope: envelope, package: dir))
        }
    }
    func testMissingUpdateDoesNotSelectAStaleBundledModel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DetectorModelStore(root: dir, documents: dir)
        XCTAssertThrowsError(try store.activateStaged())
        let loaded = try XCTUnwrap(store.load(), "Bundled YOLO26 must be present after export")
        XCTAssertEqual(loaded.1, "yolo26n-bundled-coreml")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        let image = try XCTUnwrap(context.makeImage())
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([loaded.0])
        XCTAssertNotNil(loaded.0.results as? [VNRecognizedObjectObservation],
            "Export must preserve Vision recognized-object output, including an empty result")
    }
    /// Opt-in static-image benchmark. Merely running UnitChecks does not capture or upload.
    func testStagedCandidateBenchmark() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone required")
        #else
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stage = documents.appendingPathComponent("ModelValidation")
        let benchmark = stage.appendingPathComponent("benchmark.json")
        guard FileManager.default.fileExists(atPath: benchmark.path) else { throw XCTSkip("No candidate staged for shadow validation") }
        struct Benchmark: Decodable { let dataset_sha256: String; let images: [String] }
        let spec = try JSONDecoder().decode(Benchmark.self, from: Data(contentsOf: benchmark))
        XCTAssertFalse(spec.images.isEmpty)
        XCTAssertLessThanOrEqual(spec.images.count, 2000)
        guard !spec.images.isEmpty, spec.images.count <= 2000 else { return }
        let compiled = try MLModel.compileModel(at: stage.appendingPathComponent("candidate.mlpackage"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let candidate = try DetectorModelStore.request(at: compiled)
        let baselinePackage = stage.appendingPathComponent("baseline.mlpackage")
        guard FileManager.default.fileExists(atPath: baselinePackage.path) else { throw XCTSkip("YOLO11 baseline package not staged") }
        let baselineCompiled = try MLModel.compileModel(at: baselinePackage)
        defer { try? FileManager.default.removeItem(at: baselineCompiled) }
        let baseline = try DetectorModelStore.request(at: baselineCompiled)
        var results: [[String: Any]] = [], times: [Double] = []
        for image in spec.images {
            guard image == URL(fileURLWithPath: image).lastPathComponent else { XCTFail("Unsafe image path"); return }
            let url = stage.appendingPathComponent("images").appendingPathComponent(image)
            var row: [String: Any] = ["image": image]
            for (name, request) in [("baseline", baseline), ("candidate", candidate)] {
                let start = ProcessInfo.processInfo.systemUptime
                try VNImageRequestHandler(url: url, orientation: .up).perform([request])
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if name == "candidate" { times.append(elapsed) }
                let observations = try XCTUnwrap(request.results as? [VNRecognizedObjectObservation])
                row[name] = observations.compactMap { item -> [String: Any]? in
                    guard let label = item.labels.first, label.confidence >= 0.4 else { return nil }
                    let box = item.boundingBox
                    return ["label": label.identifier, "confidence": label.confidence,
                            "box": [box.minX, 1-box.maxY, box.maxX, 1-box.minY]]
                }
            }
            results.append(row)
        }
        let sorted = times.sorted()
        let report: [String: Any] = ["dataset_sha256": spec.dataset_sha256, "physical_device": true,
            "sample_count": results.count, "p95_inference_ms": sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))],
            "observations": results, "deployment_approved": false,
            "note": "Static-image measurements only. Separate live camera, speech, rollback, thermal and battery acceptance required."]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: stage.appendingPathComponent("measurements.json"), options: .atomic)
        #endif
    }

}
