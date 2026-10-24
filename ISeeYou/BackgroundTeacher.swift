import AVFoundation
import Combine
import CoreImage
import CryptoKit
import Security
import SwiftUI
import UIKit

/// An opt-in shadow sampler. Encoding and network work never run on the inference queue.
final class BackgroundTeacher: ObservableObject, @unchecked Sendable {
    @Published var enabled = false { didSet { updateEnabled() } }
    @Published private(set) var status = "Not running — uploads off"
    @Published private(set) var detail = "No camera samples are being uploaded."
    @Published private(set) var lastReceipt = "No cloud processing receipt yet"
    @Published private(set) var modelUpdateStatus = "No signed model update checked"
    @Published private(set) var light: TeacherLight = .off
    private let worker = DispatchQueue(label: "iseeyou.teacher", qos: .utility)
    private let gate = NSLock()
    private var optedIn = false, cameraActive = false, busy = false
    private var checkingModel = false // worker queue only
    private var sessionID: String?
    private var nextFrame = 0.0, nextClip = 0.0
    private var frames: [TeacherFrame] = [] // worker queue only; at most three small images
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var timer: DispatchSourceTimer?
    private let connection: TeacherConnection?
    private let directory: URL
    private let sessionsDirectory: URL
    private let session: URLSession

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("TeacherQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionsDirectory = directory.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        var privateURL = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? privateURL.setResourceValues(values)
        connection = TeacherConnection.load()
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config)
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.retryPending() }
        timer.resume(); self.timer = timer
    }
    deinit { timer?.cancel(); session.invalidateAndCancel() }
    private var allowed: Bool { gate.withLock { optedIn && cameraActive } }
    private var sharingEnabled: Bool { gate.withLock { optedIn } }
    func cameraChanged(_ active: Bool) {
        gate.withLock {
            cameraActive = active
            if active, optedIn, sessionID == nil { sessionID = UUID().uuidString.lowercased() }
        }
        if !active {
            worker.async { [weak self] in self?.frames.removeAll() }
            if enabled { publish("Waiting for camera", "Sampling resumes only while camera frames arrive.", .queued) }
        } else if enabled { publish("Waiting for sample", "Opt-in sampling is active; uploads use Wi-Fi.", .queued) }
    }
    /// Pulls a signed Core ML package over the existing Wi-Fi-only connection.
    /// It is staged only; installing still uses the separate stopped-camera action.
    func checkForModelUpdate() {
        worker.async { [weak self] in
            guard let self, !self.checkingModel else { return }
            guard let connection = self.connection else {
                DispatchQueue.main.async { self.modelUpdateStatus = "Teacher connection is not configured" }
                return
            }
            self.checkingModel = true
            defer { self.checkingModel = false }
            var version = ""
            do {
                let response = try JSONDecoder().decode(TeacherModelUpdate.self,
                    from: self.api(connection, path: "/models/latest"))
                guard response.status == "available" else {
                    DispatchQueue.main.async { self.modelUpdateStatus = "No reviewed model release is available yet" }
                    return
                }
                guard let remoteVersion = response.version, let release = response.release, let files = response.files else {
                    throw TeacherFailure.message("Model release response is incomplete")
                }
                version = remoteVersion
                guard Self.safeModelVersion(version), files.count > 0, files.count <= 64 else {
                    throw TeacherFailure.message("Invalid model release inventory")
                }
                guard let payloadData = Data(base64Encoded: release.payload),
                      let payload = try? JSONDecoder().decode(TeacherModelPayload.self, from: payloadData),
                      payload.schema_version == 1, payload.version == version, payload.files.count == files.count else {
                    throw TeacherFailure.message("Signed model manifest does not match the release")
                }
                var expected: [String: TeacherModelPayload.File] = [:]
                for entry in payload.files {
                    guard expected[entry.path] == nil else { throw TeacherFailure.message("Duplicate model file path") }
                    expected[entry.path] = entry
                }
                guard Set(files.map(\.path)).count == files.count else { throw TeacherFailure.message("Duplicate model download path") }
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let root = documents.appendingPathComponent("ModelUpdate.partial-" + UUID().uuidString, isDirectory: true)
                let package = root.appendingPathComponent("candidate.mlpackage", isDirectory: true)
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                do {
                    var total = 0
                    for file in files {
                        guard let signed = expected[file.path], signed.size == file.size, signed.sha256 == file.sha256,
                              Self.safePackagePath(file.path), file.size > 0, file.size <= 100_000_000,
                              total <= 100_000_000 - file.size,
                              let url = URL(string: file.url), url.scheme == "https",
                              url.host?.hasSuffix(".amazonaws.com") == true else {
                            throw TeacherFailure.message("Invalid signed model file")
                        }
                        total += file.size
                        let target = package.appendingPathComponent(file.path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try self.download(url, to: target)
                        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true, values.fileSize == file.size else { throw TeacherFailure.message("Model file size mismatch") }
                        let digest = SHA256.hash(data: try Data(contentsOf: target, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                        guard digest == file.sha256 else { throw TeacherFailure.message("Model file checksum mismatch") }
                    }
                    let releaseData = try JSONSerialization.data(withJSONObject: ["payload": release.payload, "signature": release.signature], options: [.sortedKeys])
                    try releaseData.write(to: root.appendingPathComponent("release.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    var protected = root
                    var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                    try? protected.setResourceValues(flags)
                    let stage = documents.appendingPathComponent("ModelUpdate", isDirectory: true)
                    if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
                    try FileManager.default.moveItem(at: root, to: stage)
                } catch {
                    try? FileManager.default.removeItem(at: root)
                    throw error
                }
                DispatchQueue.main.async { self.modelUpdateStatus = "Signed model \(version) is staged. Stop the camera, then install it from Detector updates." }
                self.sendModelFeedback(connection, version: version, action: "staged", activeModel: "", errorCode: "")
            } catch {
                let code = Self.modelFeedbackCode(error.localizedDescription)
                DispatchQueue.main.async { self.modelUpdateStatus = "Model download failed: " + error.localizedDescription }
                if !version.isEmpty { self.sendModelFeedback(connection, version: version, action: "download_failed", activeModel: "", errorCode: code) }
            }
        }
    }
    func reportModelFeedback(version: String, action: String, activeModel: String, errorCode: String = "") {
        guard let connection = self.connection, Self.safeModelVersion(version) else { return }
        worker.async { [weak self] in self?.sendModelFeedback(connection, version: version, action: action, activeModel: activeModel, errorCode: errorCode) }
    }
    private func sendModelFeedback(_ connection: TeacherConnection, version: String, action: String, activeModel: String, errorCode: String) {
        guard let body = try? JSONSerialization.data(withJSONObject: ["action": action, "active_model": String(activeModel.prefix(80)),
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "", "error_code": errorCode]) else { return }
        _ = try? api(connection, path: "/models/\(version)/feedback", method: "POST", body: body)
    }
    private func download(_ url: URL, to destination: URL) throws {
        let done = DispatchSemaphore(value: 0), result = TeacherDownloadResult()
        var request = URLRequest(url: url); request.timeoutInterval = 600; request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.downloadTask(with: request) { location, response, error in
            result.error = error
            result.code = (response as? HTTPURLResponse)?.statusCode
            if let location {
                do { try FileManager.default.moveItem(at: location, to: destination) }
                catch { result.error = error }
            }
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + 620) == .success else { task.cancel(); throw TeacherFailure.message("Model download timed out") }
        if let error = result.error { throw error }
        guard result.code == 200 else { throw TeacherFailure.message("Model file download was rejected") }
    }
    private static func safeModelVersion(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
    }
    private static func safePackagePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.count <= 12 && path.count <= 500 && !path.contains("\\") &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-").contains($0) } }
    }
    private static func modelFeedbackCode(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("signature") { return "signature" }
        if lower.contains("checksum") { return "checksum" }
        if lower.contains("compile") { return "compile" }
        if lower.contains("compatibility") || lower.contains("vision") || lower.contains("detector") { return "compatibility" }
        if lower.contains("size") || lower.contains("file") { return "download" }
        return "unknown"
    }
    private func updateEnabled() {
        gate.withLock {
            optedIn = enabled; nextFrame = 0; nextClip = 0
            if enabled, cameraActive, sessionID == nil { sessionID = UUID().uuidString.lowercased() }
        }
        worker.async { [weak self] in self?.frames.removeAll() }
        if !enabled { publish("Not running — uploads off", "No new samples will be captured or uploaded. An in-flight request may finish.", .off) }
        else if connection == nil { publish("Not connected", "The private teacher connection has not been configured on this phone.", .error) }
        else { publish("Waiting for camera/sample", "Three low-rate frames form a short clip. Mock test responses are explicitly labelled.", .queued) }
    }
    /// Called only by the explicit Stop camera action. Lifecycle stops leave the session open.
    func endSession() {
        let endedID = gate.withLock { () -> String? in
            cameraActive = false
            defer { sessionID = nil }
            return sessionID
        }
        guard let endedID else { return }
        worker.async { [weak self] in
            guard let self else { return }
            let file = self.sessionsDirectory.appendingPathComponent(endedID + ".json")
            var record = (try? JSONDecoder().decode(TeacherSessionRecord.self, from: Data(contentsOf: file)))
                ?? TeacherSessionRecord(session_id: endedID, sample_ids: [], ended: false, completion_sent: false)
            record.ended = true
            try? JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            self.drainPending()
            self.completeEndedSessions()
        }
    }
    func offer(_ buffer: CVPixelBuffer, detections: [Detection], source: String, modelVersion: String) {
        guard connection != nil else { return }
        let now = CACurrentMediaTime()
        let acceptedSession = gate.withLock { () -> String? in
            guard optedIn, cameraActive, !busy, now >= nextFrame, now >= nextClip else { return nil }
            if sessionID == nil { sessionID = UUID().uuidString.lowercased() }
            busy = true; nextFrame = now + 1
            return sessionID
        }
        guard let acceptedSession else { return }
        let predictions = detections.prefix(100).map { detection in
            TeacherPrediction(label: detection.label, confidence: Double(detection.confidence),
                box: [max(0, Double(detection.bounds.minX)), max(0, 1 - Double(detection.bounds.maxY)),
                      min(1, Double(detection.bounds.maxX)), min(1, 1 - Double(detection.bounds.minY))])
        }.filter { $0.box[0] < $0.box[2] && $0.box[1] < $0.box[3] }
        worker.async { [weak self] in
            guard let self else { return }
            defer { self.gate.withLock { self.busy = false } }
            guard self.allowed else { return }
            guard ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair else {
                self.frames.removeAll(); self.publish("Paused — phone is warm", "Local detection continues; teacher capture is paused.", .queued); return
            }
            do {
                let image = CIImage(cvPixelBuffer: buffer)
                let scale = min(1, 512 / max(image.extent.width, image.extent.height))
                let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cg = self.context.createCGImage(small, from: small.extent),
                      let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { return }
                if let first = self.frames.first, now - first.monotonic > 4 { self.frames.removeAll() }
                self.frames.append(TeacherFrame(jpeg: jpeg, capturedAt: Date(), monotonic: now, predictions: predictions))
                self.publish("Sampling a short clip", "\(self.frames.count) of 3 low-rate frames captured.", .queued)
                guard self.frames.count == 3 else { return }
                defer { self.frames.removeAll(); self.gate.withLock { self.nextClip = CACurrentMediaTime() + 60 } }
                try self.makePendingClip(source: source, modelVersion: modelVersion, sessionID: acceptedSession)
                self.drainPending()
            } catch { self.publish("Sample queued or unavailable", "Teacher work paused; local camera and speech continue.", .error) }
        }
    }
    private func publish(_ text: String, _ explanation: String, _ level: TeacherLight) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.enabled || level == .off else { return }
            self.status = text; self.detail = explanation; self.light = level
        }
    }
    private func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func makePendingClip(source: String, modelVersion: String, sessionID: String) throws {
        guard pending().count < 4 else { publish("Queue full — sampling paused", "Four clips are waiting. No more samples will be stored until space is available.", .queued); return }
        let id = UUID().uuidString.lowercased(), folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let imageURL = folder.appendingPathComponent("frame.jpg"), clipURL = folder.appendingPathComponent("clip.mp4")
            try frames[0].jpeg.write(to: imageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            for index in 1..<frames.count {
                try frames[index].jpeg.write(to: folder.appendingPathComponent("frame-\(index).jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try encodeClip(to: clipURL)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: clipURL.path)
            let clip = try Data(contentsOf: clipURL)
            guard clip.count <= 6_000_000 else { throw TeacherFailure.message("Clip too large") }
            let first = frames[0]
            let metadata = frames.enumerated().map { index, frame in
                TeacherFrameMetadata(frame_id: id + "-\(index)", offset_seconds: frame.monotonic - first.monotonic,
                    captured_at: ISO8601DateFormatter().string(from: frame.capturedAt),
                    image_size: frame.jpeg.count, image_sha256: Data(SHA256.hash(data: frame.jpeg)).base64EncodedString(),
                    predictions: frame.predictions)
            }
            let manifest = TeacherManifest(sample_id: id, session_id: sessionID, frame_id: id + "-0", captured_at: ISO8601DateFormatter().string(from: first.capturedAt),
                model_version: modelVersion, predictions: first.predictions, source: source,
                duration_seconds: frames.last!.monotonic - first.monotonic + 1, image_size: first.jpeg.count, clip_size: clip.count,
                image_sha256: Data(SHA256.hash(data: first.jpeg)).base64EncodedString(),
                clip_sha256: Data(SHA256.hash(data: clip)).base64EncodedString(),
                clip_frames: metadata)
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let sessionFile = sessionsDirectory.appendingPathComponent(sessionID + ".json")
            var record = (try? JSONDecoder().decode(TeacherSessionRecord.self, from: Data(contentsOf: sessionFile)))
                ?? TeacherSessionRecord(session_id: sessionID, sample_ids: [], ended: false, completion_sent: false)
            if !record.sample_ids.contains(id) { record.sample_ids.append(id) }
            try JSONEncoder().encode(record).write(to: sessionFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    #if DEBUG
    // Device test uses generated pixels only; it cannot sample a camera or upload.
    func encodeSyntheticClipForTest(to url: URL) throws {
        try worker.sync {
            let image = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
            guard let cg = context.createCGImage(image, from: image.extent),
                  let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6) else { throw TeacherFailure.message("No fixture") }
            frames = (0..<3).map { TeacherFrame(jpeg: jpeg, capturedAt: Date(), monotonic: Double($0), predictions: []) }
            defer { frames.removeAll() }
            try encodeClip(to: url)
        }
    }
    #endif
    private func encodeClip(to url: URL) throws {
        guard let first = UIImage(data: frames[0].jpeg)?.cgImage else { throw TeacherFailure.message("No image") }
        let width = first.width / 2 * 2, height = first.height / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 200_000, AVVideoExpectedSourceFrameRateKey: 1, AVVideoAllowFrameReorderingKey: false]])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw TeacherFailure.message("Encoder unavailable") }
        writer.startSession(atSourceTime: .zero)
        for frame in frames {
            let deadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            guard input.isReadyForMoreMediaData, let image = UIImage(data: frame.jpeg)?.cgImage else { writer.cancelWriting(); throw TeacherFailure.message("Encoder backpressure") }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
            guard let pixel else { writer.cancelWriting(); throw TeacherFailure.message("No buffer") }
            context.render(CIImage(cgImage: image), to: pixel)
            guard adapter.append(pixel, withPresentationTime: CMTime(seconds: frame.monotonic - frames[0].monotonic, preferredTimescale: 600)) else {
                writer.cancelWriting(); throw TeacherFailure.message("Encoder failed")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: frames.last!.monotonic - frames[0].monotonic + 1, preferredTimescale: 600)); input.markAsFinished()
        let complete = DispatchSemaphore(value: 0)
        writer.finishWriting { complete.signal() }
        guard complete.wait(timeout: .now() + 10) == .success, writer.status == .completed else {
            writer.cancelWriting(); throw TeacherFailure.message("Encoder timed out")
        }
    }
    private func retryPending() {
        // Expiry runs even when sharing is off, whenever the app gets execution time.
        for folder in pending() {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
               let doc = try? JSONDecoder().decode(TeacherManifest.self, from: data),
               Date().timeIntervalSince(ISO8601DateFormatter().date(from: doc.captured_at) ?? .distantPast) > 86_400 {
                removeExpiredSample(doc.sample_id, sessionID: doc.session_id)
                try? FileManager.default.removeItem(at: folder)
            }
        }
        guard connection != nil, sharingEnabled else { completeEndedSessions(); return }
        let accept = gate.withLock { () -> Bool in
            guard optedIn, !busy else { return false }; busy = true; return true
        }
        guard accept else { return }
        defer { gate.withLock { busy = false } }
        drainPending()
        completeEndedSessions()
        pollEndedSessions()
    }
    private func drainPending() {
        guard let connection, sharingEnabled else { return }
        for folder in pending() {
            guard sharingEnabled else { return }
            let manifestURL = folder.appendingPathComponent("manifest.json")
            do {
                let data = try Data(contentsOf: manifestURL), doc = try JSONDecoder().decode(TeacherManifest.self, from: data)
                if Date().timeIntervalSince(ISO8601DateFormatter().date(from: doc.captured_at) ?? .distantPast) > 86_400 {
                    removeExpiredSample(doc.sample_id, sessionID: doc.session_id)
                    try? FileManager.default.removeItem(at: folder); continue
                }
                let retryURL = folder.appendingPathComponent("retry.json")
                let retry = (try? JSONDecoder().decode(TeacherRetry.self, from: Data(contentsOf: retryURL))) ?? TeacherRetry(attempts: 0, after: .distantPast)
                guard retry.attempts < 20, retry.after <= Date() else { continue }
                let next = TeacherRetry(attempts: retry.attempts + 1, after: Date().addingTimeInterval(min(3600, 30 * pow(2, Double(min(retry.attempts, 7))))))
                try JSONEncoder().encode(next).write(to: retryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                publish("Uploading queued clip", "Wi-Fi only. Local detection and speech do not wait for uploads.", .queued)
                let ticketData = try api(connection, path: "/samples", method: "POST", body: data)
                let ticket = try JSONDecoder().decode(TeacherTicket.self, from: ticketData)
                var uploads: [(String, TeacherTicket.Upload)] = [("frame.jpg", ticket.image), ("clip.mp4", ticket.clip)]
                uploads += ticket.frames.enumerated().map { ("frame-\($0.offset + 1).jpg", $0.element) }
                for (media, target) in uploads {
                    guard sharingEnabled else { return }
                    guard let url = URL(string: target.url), url.scheme == "https", url.host?.hasSuffix(".amazonaws.com") == true else { throw TeacherFailure.message("Invalid upload URL") }
                    var request = URLRequest(url: url); request.httpMethod = "PUT"
                    request.allHTTPHeaderFields = target.headers
                    request.httpBody = try Data(contentsOf: folder.appendingPathComponent(media))
                    _ = try send(request, accepted: [200, 412])
                }
                guard sharingEnabled else { return }
                _ = try api(connection, path: "/samples/\(doc.sample_id)/complete", method: "POST", body: Data("{}".utf8))
                // Completion verifies both durable object versions and checksums before local deletion.
                try FileManager.default.removeItem(at: folder)
                let receipt = TeacherPendingReceipt(sample: doc.sample_id, created: Date())
                try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                publish("Uploaded — processing queued", "The server confirmed both files. Waiting for a processing receipt.", .queued)
            } catch {
                publish("Queued — upload will retry", "A network or server error occurred. Files remain private on this phone for up to 24 hours.", .error)
                break
            }
        }
        completeEndedSessions()
        guard sharingEnabled, let data = try? Data(contentsOf: directory.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(TeacherPendingReceipt.self, from: data) else { return }
        do {
            let result = try JSONDecoder().decode(TeacherReceipt.self, from: api(connection, path: "/samples/\(receipt.sample)"))
            if result.status == "mock_complete" || result.status == "proposed_only" || result.status == "pseudo_labeled" || result.status == "budget_limited" {
                let mock = result.status == "mock_complete"
                var description = mock ? "Mock processing confirmed — no AI analysis" :
                    (result.status == "budget_limited" ? "Monthly learning budget reached — no more Nova calls started" : "Nova labels saved as pseudo-labels; YOLO training is separate and asynchronous")
                if let feedback = result.feedback, result.status == "pseudo_labeled" {
                    if !feedback.additional_labels.isEmpty {
                        description += ". Nova saw: " + feedback.additional_labels.prefix(6).joined(separator: ", ")
                    }
                    if !feedback.detector_only_labels.isEmpty {
                        description += ". Detector-only: " + feedback.detector_only_labels.prefix(6).joined(separator: ", ")
                    }
                    description = String(description.prefix(600))
                }
                DispatchQueue.main.async { [weak self] in self?.lastReceipt = description + " at " + Date().formatted(date: .omitted, time: .shortened) }
                publish(mock ? "Mock complete" : "Teacher response received", description, mock ? .queued : .verified)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("receipt.json"))
            }
        } catch { publish("Uploaded — receipt pending", "Cloud status could not be checked yet; this is not a confirmed analysis.", .queued) }
    }
    private func completeEndedSessions() {
        guard sharingEnabled, let connection else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard var record = try? JSONDecoder().decode(TeacherSessionRecord.self, from: Data(contentsOf: file)),
                  record.ended, !record.completion_sent else { continue }
            let hasPending = pending().contains { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONDecoder().decode(TeacherManifest.self, from: data) else { return false }
                return manifest.session_id == record.session_id
            }
            guard !hasPending else { continue }
            do {
                let body = try JSONSerialization.data(withJSONObject: ["sample_count": record.sample_ids.count])
                _ = try api(connection, path: "/sessions/\(record.session_id)/complete", method: "POST", body: body)
                record.completion_sent = true
                try JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                publish("Session sent for background teaching", "Nova processing and YOLO training run asynchronously within the monthly budget.", .queued)
            } catch {
                publish("Session queued for processing", "The session close signal will retry when Wi-Fi is available.", .queued)
            }
        }
    }
    private func removeExpiredSample(_ sampleID: String, sessionID: String?) {
        guard let sessionID else { return }
        let file = sessionsDirectory.appendingPathComponent(sessionID + ".json")
        guard var record = try? JSONDecoder().decode(TeacherSessionRecord.self, from: Data(contentsOf: file)) else { return }
        record.sample_ids.removeAll { $0 == sampleID }
        try? JSONEncoder().encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func pollEndedSessions() {
        guard sharingEnabled, let connection else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let record = try? JSONDecoder().decode(TeacherSessionRecord.self, from: Data(contentsOf: file)),
                  record.ended, record.completion_sent else { continue }
            do {
                let status = try JSONDecoder().decode(TeacherSessionReceipt.self,
                    from: api(connection, path: "/sessions/\(record.session_id)")).status
                let finished = ["training_complete", "training_failed", "training_stopped", "no_samples",
                                "awaiting_more_pseudo_labels", "evaluation_rejected", "budget_limited", "processing_timeout"]
                let explanation = status == "evaluation_rejected"
                    ? "The held-out Nova-labeled set did not meet the YOLO quality gates. The current phone model remains unchanged."
                    : "Nova labels and YOLO training are processed asynchronously. The app continues using its current model until a signed release is available and installed."
                let detail = "Session \(record.session_id.prefix(8)): \(status)"
                DispatchQueue.main.async { [weak self] in self?.lastReceipt = detail }
                publish(finished.contains(status) ? "Background teaching: \(status)" : "Background teaching: \(status)",
                        explanation,
                        finished.contains(status) ? .verified : .queued)
            } catch { /* The server can be temporarily unavailable; the next timer tick retries. */ }
        }
    }
    private func api(_ connection: TeacherConnection, path: String, method: String = "GET", body: Data? = nil) throws -> Data {
        guard let url = URL(string: connection.endpoint + path), url.scheme == "https" else { throw TeacherFailure.message("Invalid connection") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try send(request, accepted: [200, 201, 202])
    }
    private func send(_ request: URLRequest, accepted: Set<Int>) throws -> Data {
        let complete = DispatchSemaphore(value: 0), result = TeacherNetworkResult()
        let task = session.dataTask(with: request) { data, response, error in
            result.data = data; result.code = (response as? HTTPURLResponse)?.statusCode; result.error = error; complete.signal()
        }
        task.resume()
        guard complete.wait(timeout: .now() + 40) == .success else { task.cancel(); throw TeacherFailure.message("Network timeout") }
        if let error = result.error { throw error }
        guard let code = result.code, accepted.contains(code) else { throw TeacherFailure.message("Request rejected") }
        return result.data ?? Data()
    }
}

enum TeacherLight { case off, queued, verified, error
    var color: Color { switch self { case .off: return .secondary; case .queued: return .orange; case .verified: return .green; case .error: return .red } }
}
private struct TeacherFrame { let jpeg: Data; let capturedAt: Date; let monotonic: Double; let predictions: [TeacherPrediction] }
private struct TeacherPrediction: Codable { let label: String; let confidence: Double; let box: [Double] }
private struct TeacherFrameMetadata: Codable {
    let frame_id: String
    let offset_seconds: Double
    let captured_at: String
    let image_size: Int
    let image_sha256: String
    let predictions: [TeacherPrediction]
}
private struct TeacherManifest: Codable {
    let schema_version = 1, consent = true
    let sample_id: String, session_id: String, frame_id: String, captured_at: String, model_version: String
    let predictions: [TeacherPrediction]; let source: String; let duration_seconds: Double
    let image_size: Int, clip_size: Int; let image_sha256: String, clip_sha256: String
    let clip_frames: [TeacherFrameMetadata]
}
private struct TeacherTicket: Decodable {
    struct Upload: Decodable { let url: String; let headers: [String: String] }
    let image: Upload, clip: Upload
    let frames: [Upload]
}
private struct TeacherSessionRecord: Codable { let session_id: String; var sample_ids: [String]; var ended: Bool; var completion_sent: Bool }
private struct TeacherSessionReceipt: Decodable { let status: String }
private struct TeacherModelUpdate: Decodable {
    let status: String
    let version: String?
    let release: TeacherModelEnvelope?
    let files: [TeacherModelFile]?
}
private struct TeacherModelEnvelope: Decodable { let payload: String; let signature: String }
private struct TeacherModelFile: Decodable { let path: String; let size: Int; let sha256: String; let url: String }
private struct TeacherModelPayload: Decodable {
    struct File: Decodable { let path: String; let size: Int; let sha256: String }
    let schema_version: Int; let version: String; let files: [File]
}
private struct TeacherReceipt: Decodable { let status: String; let feedback: TeacherFeedback? }
private struct TeacherFeedback: Decodable {
    let additional_labels: [String]
    let detector_only_labels: [String]
    let frames: [TeacherFeedbackFrame]
    let is_nova_pseudo_feedback: Bool
}
private struct TeacherFeedbackFrame: Decodable { let frame_id: String; let summary: String }
private struct TeacherRetry: Codable { let attempts: Int; let after: Date }
private struct TeacherPendingReceipt: Codable { let sample: String; let created: Date }
private final class TeacherNetworkResult: @unchecked Sendable { var data: Data?; var code: Int?; var error: Error? }
private final class TeacherDownloadResult: @unchecked Sendable { var code: Int?; var error: Error? }
private enum TeacherFailure: Error { case message(String) }
private struct TeacherConnection: Codable {
    let endpoint: String, token: String
    static func load() -> TeacherConnection? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.iseeyou.teacher", kSecAttrAccount as String: "connection"]
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("teacher-connection.json")
        if let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Self.self, from: data),
           URL(string: config.endpoint)?.scheme == "https", URL(string: config.endpoint)?.host?.hasSuffix(".execute-api.eu-west-2.amazonaws.com") == true, config.token.count >= 32 {
            SecItemDelete(query as CFDictionary)
            var save = query; save[kSecValueData as String] = data
            save[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if SecItemAdd(save as CFDictionary, nil) == errSecSuccess { try? FileManager.default.removeItem(at: file); return config }
        }
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
