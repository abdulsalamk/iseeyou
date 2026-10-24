import Foundation
import CoreML
import CryptoKit
import Vision

/// Signed model updates are staged from the local Mac. No network, camera, or automatic promotion.
final class DetectorModelStore {
    struct FileEntry: Codable { let path: String; let size: Int; let sha256: String }
    struct Payload: Codable {
        let schema_version: Int
        let version: String
        let files: [FileEntry]
        let evaluation_sha256: String
        let device_report_sha256: String
    }
    private struct Envelope: Codable { let payload: String; let signature: String }
    private struct State: Codable { var current: String?; var previous: String? }
    private let root: URL
    private let documents: URL
    private let publicKey: Data?
    private let fm = FileManager.default
    private let lock = NSLock()

    init(root: URL? = nil, documents: URL? = nil, publicKey: Data? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DetectorModels")
        self.documents = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.publicKey = publicKey ?? Bundle.main.url(forResource: "ModelSigningPublicKey", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { Data(base64Encoded: $0) }
    }
    private func state() -> State {
        (try? JSONDecoder().decode(State.self, from: Data(contentsOf: root.appendingPathComponent("state.json")))) ?? State()
    }
    private func save(_ state: State) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    private func safeVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 80 && version.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
    }
    func verifiedPayload(envelope: Data, package suppliedPackage: URL) throws -> Payload {
        let package = suppliedPackage.resolvingSymlinksInPath().standardizedFileURL
        guard envelope.count <= 100_000, let publicKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { throw ModelUpdateError.invalid }
        let signed = try JSONDecoder().decode(Envelope.self, from: envelope)
        guard let data = Data(base64Encoded: signed.payload), let signature = Data(base64Encoded: signed.signature),
              key.isValidSignature(signature, for: data) else { throw ModelUpdateError.rejected("signature") }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.schema_version == 1, safeVersion(payload.version), !payload.files.isEmpty, payload.files.count <= 64,
              payload.evaluation_sha256.count == 64, payload.device_report_sha256.count == 64 else { throw ModelUpdateError.rejected("manifest") }
        var paths = Set<String>(), total = 0
        for file in payload.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !file.path.contains("\\"), paths.insert(file.path).inserted,
                  file.size > 0, file.size <= 100_000_000, total <= 100_000_000 - file.size else { throw ModelUpdateError.rejected("file path or size") }
            total += file.size
            let url = package.appendingPathComponent(file.path)
            guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw ModelUpdateError.rejected("symbolic link") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == file.size else { throw ModelUpdateError.rejected("file size") }
            let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else { throw ModelUpdateError.rejected("file checksum") }
        }
        guard let enumerator = fm.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw ModelUpdateError.invalid }
        var actual = Set<String>()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ModelUpdateError.invalid }
            if values.isRegularFile == true {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonical.hasPrefix(package.path + "/") else { throw ModelUpdateError.rejected("file boundary") }
                actual.insert(String(canonical.dropFirst(package.path.count + 1)))
            }
        }
        guard actual == paths else { throw ModelUpdateError.rejected("file inventory") }
        return payload
    }
    static func request(at url: URL) throws -> VNCoreMLRequest {
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: config)
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        return request
    }
    func load() throws -> (VNCoreMLRequest, String)? {
        lock.lock(); defer { lock.unlock() }
        let saved = state()
        for version in [saved.current, saved.previous].compactMap({ $0 }) where safeVersion(version) {
            if version.hasSuffix("-bundled-coreml") {
                let name = String(version.dropLast("-bundled-coreml".count))
                if let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                   let request = try? Self.request(at: bundled) { return (request, version) }
                continue
            }
            if let request = try? Self.request(at: root.appendingPathComponent(version).appendingPathComponent("model.mlmodelc")) {
                return (request, version)
            }
        }
        for name in ["yolo26n", "yolo11n"] {
            guard let bundled = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                  let request = try? Self.request(at: bundled) else { continue }
            return (request, name + "-bundled-coreml")
        }
        return nil
    }
    func activateStaged() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let stage = documents.appendingPathComponent("ModelUpdate")
        let package = stage.appendingPathComponent("candidate.mlpackage")
        let envelope = try Data(contentsOf: stage.appendingPathComponent("release.json"))
        let payload = try verifiedPayload(envelope: envelope, package: package)
        let current = state()
        let target = root.appendingPathComponent(payload.version)
        guard current.current != payload.version, current.previous != payload.version, !fm.fileExists(atPath: target.path) else { throw ModelUpdateError.versionExists }
        let compiled = try MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        let request = try Self.request(at: compiled)
        // Ensure Vision recognizes the exported NMS detector output before changing active state.
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 640, 640, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess, let pixel else { throw ModelUpdateError.invalid }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) { memset(address, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up).perform([request])
        guard request.results is [VNRecognizedObjectObservation] else { throw ModelUpdateError.invalid }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: compiled, to: target.appendingPathComponent("model.mlmodelc"))
            try envelope.write(to: target.appendingPathComponent("release.json"), options: .atomic)
            var exclude = root
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try exclude.setResourceValues(flags)
            try save(State(current: payload.version, previous: current.current))
        } catch { try? fm.removeItem(at: target); throw error }
        if let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let keep = Set([payload.version, current.current].compactMap { $0 })
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !keep.contains(entry.lastPathComponent) {
                try? fm.removeItem(at: entry)
            }
        }
        // Remove one-time handoff only after a durable verified installation.
        try? fm.removeItem(at: stage)
        return payload.version
    }
    func useYOLO11Baseline() throws {
        lock.lock(); defer { lock.unlock() }
        try save(State(current: "yolo11n-bundled-coreml", previous: nil))
    }
    func stagedVersion() -> String? {
        lock.lock(); defer { lock.unlock() }
        let envelopeURL = documents.appendingPathComponent("ModelUpdate/release.json")
        guard let data = try? Data(contentsOf: envelopeURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let payloadData = Data(base64Encoded: envelope.payload),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData), safeVersion(payload.version) else { return nil }
        return payload.version
    }
}

enum ModelUpdateError: LocalizedError {
    case invalid, versionExists, rejected(String)
    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return "Model update rejected: " + reason + ". The current detector is unchanged."
        case .invalid: return "Model update failed signature, integrity, or detector compatibility checks. The current detector is unchanged."
        case .versionExists: return "This model version is already installed. Use a new signed version."
        }
    }
}
