import AVFoundation
import Speech
import Combine
import CoreImage
import CryptoKit
import UIKit

struct CorrectionCommand {
    static func label(_ text: String) -> String? {
        let normalized = text.lowercased().replacingOccurrences(of: "[,.;:!?]", with: " ", options: .regularExpression).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let prefix = "correction this is "
        guard normalized.hasPrefix(prefix) else { return nil }
        var label = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet.letters.inverted)
        for article in ["a ", "an ", "the "] where label.hasPrefix(article) { label = String(label.dropFirst(article.count)); break }
        guard !label.isEmpty, !["a", "an", "the"].contains(label), label.count <= 60, label.split(separator: " ").count <= 6,
              label.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == " " || $0 == "-" }) else { return nil }
        return label
    }
    static func command(in text: String) -> String? {
        guard let range = text.range(of: "\\bcorrection\\b", options: [.regularExpression, .caseInsensitive, .backwards]) else { return nil }
        return String(text[range.lowerBound...])
    }
    static func association(_ detections: [Detection]) -> Detection? {
        // Never guess which of several visible objects a volunteer means.
        guard detections.count == 1 else { return nil }
        return detections[0]
    }
}

/// Speech can return a complete command as a partial result indefinitely.
/// A revision-bound quiet period accepts it once, without waiting for isFinal.
struct CorrectionTranscriptState {
    private(set) var text = ""
    private var revision = 0
    private var consumed = false
    mutating func update(_ value: String, isFinal: Bool = false) -> Int? {
        guard !consumed, value != text || isFinal else { return nil }
        text = value; revision += 1; return revision
    }
    mutating func take(revision expected: Int) -> String? {
        guard !consumed, expected == revision, CorrectionCommand.label(text) != nil else { return nil }
        consumed = true; return text
    }
}

struct CorrectionRetry: Codable {
    var attempts = 0
    var after = Date.distantPast
    mutating func failed(now: Date) { attempts += 1; after = now.addingTimeInterval(min(3600, pow(2, Double(min(attempts, 10))) * 15)) }
    func ready(now: Date, idle: Bool) -> Bool { idle && attempts < 8 && now >= after }
}

/// One bounded input slot, three small JPEGs, and a separate utility queue.
/// Neither encoding nor network requests run on the inference queue.
final class HumanTeacher: ObservableObject, @unchecked Sendable {
    @Published var enabled = false { didSet { configure() } }
    @Published private(set) var status = "Teacher Mode off"
    @Published private(set) var microphoneStatus = "Microphone off"
    @Published private(set) var commandPreview = "No correction command heard"
    @Published private(set) var lastSaved = "No correction saved this session"
    private var transcriptState = CorrectionTranscriptState() // work queue only
    private var lastMeter = Date.distantPast // lock protected
    private var recognitionResults = 0 // main thread only
    private let work = DispatchQueue(label: "iseeyou.human-teacher", qos: .utility)
    private let lock = NSLock()
    private var accepting = false, active = false, foreground = true, slot = false
    private var epoch = UUID()
    private var speechLease = UUID()
    private var lastFrame = Date.distantPast
    private struct Frame { let jpeg: Data; let detections: [Detection]; let date: Date; let version: String; let source: String }
    private var frames: [Frame] = [] // work queue only
    private var anchor: Frame?
    private var lastCorrection: UUID?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let audio = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapped = false
    private var recognitionFailures = 0
    private var restart: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private let directory: URL
    private let connection: TeacherConnection?
    private let network: URLSession

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HumanCorrections")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var url = self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        connection = TeacherConnection.load()
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false; config.allowsExpensiveNetworkAccess = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45
        network = URLSession(configuration: config)
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 15, repeating: 30)
        timer.setEventHandler { [weak self] in self?.uploadPending() }
        timer.resume(); self.timer = timer
    }
    deinit { timer?.cancel(); recognition?.cancel(); network.invalidateAndCancel() }
    private func publish(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.status = message
            if message.hasPrefix("Correction") || message.hasPrefix("No recent") || message.hasPrefix("Use ‘Correction") { self.lastSaved = message }
            self.saveDiagnostics()
        }
    }
    private func saveDiagnostics() {
        let snapshot: [String: Any] = ["updatedAt": ISO8601DateFormatter().string(from: Date()),
            "status": status, "microphone": microphoneStatus, "command": commandPreview,
            "recognitionResults": recognitionResults, "enabled": enabled, "lastSaved": lastSaved]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        let file = directory.deletingLastPathComponent().appendingPathComponent("HumanTeacherStatus.json")
        work.async {
            try? data.write(to: file, options: [.atomic, .completeFileProtection])
            var url = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
    private func inputArrived(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard lock.withLock({ () -> Bool in
            guard accepting, now.timeIntervalSince(lastMeter) >= 1 else { return false }
            lastMeter = now; return true
        }) else { return }
        var peak: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
        }
        let message = peak > 0.002 ? "Microphone input arriving — sound detected" : "Microphone input arriving — quiet"
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.accepting }), CorrectionAudio.listening else { return }
            self.microphoneStatus = message + " · " + AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portName).joined(separator: ", "); self.saveDiagnostics()
        }
    }
    private func restartSpeech(lease: UUID, utterance: UUID, error: Error? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.accepting && self.epoch == lease && self.speechLease == utterance }) else { return }
            self.stopListening()
            self.recognitionFailures = error == nil ? 0 : self.recognitionFailures + 1
            if let error {
                let e = error as NSError
                self.publish("Speech error (\(e.domain) \(e.code)); retrying")
            }
            guard self.recognitionFailures < 3 else { self.publish("On-device speech stopped after repeated errors; toggle Teacher Mode to retry"); return }
            let restart = DispatchWorkItem { [weak self] in self?.listen() }; self.restart = restart
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restart)
        }
    }
    func cameraChanged(_ running: Bool) {
        lock.withLock { active = running; epoch = UUID(); accepting = enabled && foreground && running }
        configure()
        if !running { work.async { [weak self] in self?.frames.removeAll(); self?.anchor = nil; self?.uploadPending() } }
    }
    func foregroundChanged(_ value: Bool) {
        lock.withLock { foreground = value; epoch = UUID(); accepting = enabled && value && active }
        configure()
    }
    private func configure() {
        stopListening()
        recognitionFailures = 0
        let allowed = lock.withLock { () -> Bool in epoch = UUID(); accepting = enabled && foreground && active; return accepting }
        if !enabled { work.async { [weak self] in self?.frames.removeAll(); self?.anchor = nil }; publish("Teacher Mode off — queued corrections upload only while app is idle"); return }
        guard allowed else { publish("Teacher Mode waiting — start camera; keep app visible"); return }
        let lease = lock.withLock { epoch }
        SFSpeechRecognizer.requestAuthorization { [weak self] permission in
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard let self, self.lock.withLock({ self.accepting && self.epoch == lease }) else { return }
                    guard permission == .authorized && granted else { self.publish("Teacher Mode needs Speech and Microphone permission in Settings"); return }
                    self.listen()
                }
            }
        }
    }
    private func stopListening() {
        lock.withLock { speechLease = UUID() }
        restart?.cancel(); restart = nil
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        audio.stop()
        microphoneStatus = "Microphone off"
        if CorrectionAudio.listening || tapped {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        }
        CorrectionAudio.listening = false; if tapped { audio.inputNode.removeTap(onBus: 0); tapped = false }
    }
    private func listen() {
        guard lock.withLock({ accepting }), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")), recognizer.isAvailable else { publish("Speech recognition unavailable; Teacher Mode is not listening"); return }
        // Require local recognition: no audio is sent to Apple or uploaded to S3.
        guard recognizer.supportsOnDeviceRecognition else { publish("On-device English speech unavailable; download the language or use a supported device"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request
            let node = audio.inputNode, format = audio.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { publish("Microphone unavailable"); return }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in request.append(buffer); self?.inputArrived(buffer) }; tapped = true
            audio.prepare(); try audio.start(); CorrectionAudio.listening = true
            microphoneStatus = "Waiting for microphone input"
            work.async { [weak self] in self?.anchor = nil; self?.transcriptState = CorrectionTranscriptState() }
            let utterance = UUID()
            let lease = lock.withLock { speechLease = utterance; return epoch }
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self, self.lock.withLock({ self.accepting && self.epoch == lease && self.speechLease == utterance }) else { return }
                if let result {
                    let command = CorrectionCommand.command(in: result.bestTranscription.formattedString)
                    DispatchQueue.main.async {
                        self.recognitionResults += 1
                        if let command { self.commandPreview = "Heard: " + String(command.prefix(300)) }
                        else { self.commandPreview = "Speech recognized — waiting for ‘Correction, this is …’" }
                        self.saveDiagnostics()
                    }
                    if let command {
                        self.acceptTranscript(command, final: result.isFinal, receivedAt: Date(), lease: lease, utterance: utterance)
                    }
                    // A final result is allowed to finish its queued capture before restart.
                    if result.isFinal || error != nil {
                        self.work.asyncAfter(deadline: .now() + 0.1) { self.restartSpeech(lease: lease, utterance: utterance, error: error) }
                    }
                } else if let error { self.restartSpeech(lease: lease, utterance: utterance, error: error) }

            }
            publish("Listening on device — say ‘Correction, this is a piano’. Aim at one object.")
        } catch { stopListening(); publish("Teacher microphone could not start; navigation remains available") }
    }
    private func acceptTranscript(_ command: String, final: Bool, receivedAt now: Date, lease: UUID, utterance: UUID, restartAfterCapture: Bool = true) {
        work.async { [weak self] in
            guard let self, self.lock.withLock({ self.accepting && self.epoch == lease && self.speechLease == utterance }) else { return }
            if self.anchor == nil { self.anchor = self.frames.last(where: { now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 2 }) }
            guard let revision = self.transcriptState.update(command, isFinal: final) else { return }
            self.work.asyncAfter(deadline: .now() + (final ? 0 : 1.2)) { [weak self] in
                guard let self, self.lock.withLock({ self.accepting && self.epoch == lease && self.speechLease == utterance }),
                      self.lastCorrection != utterance,
                      let text = self.transcriptState.take(revision: revision) else { return }
                self.lastCorrection = utterance
                self.capture(text, lease: lease)
                if restartAfterCapture { self.restartSpeech(lease: lease, utterance: utterance) }
            }
        }
    }
    func offer(_ buffer: CVPixelBuffer, detections: [Detection], modelVersion: String, source: String) {
        let now = Date()
        let lease: UUID? = lock.withLock {
            guard accepting, !slot, now.timeIntervalSince(lastFrame) >= 0.5 else { return nil }
            slot = true; lastFrame = now; return epoch
        }
        guard let lease else { return }
        work.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.slot = false } }
            guard self.lock.withLock({ self.accepting && self.epoch == lease }) else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = self.context.createCGImage(resized, from: resized.extent), let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7) else { return }
            self.frames.append(Frame(jpeg: jpeg, detections: detections, date: now, version: modelVersion, source: source))
            self.frames = Array(self.frames.suffix(3))
        }
    }
    private func capture(_ text: String, lease: UUID) {
        defer { anchor = nil }
        guard lock.withLock({ accepting && epoch == lease }) else { return }
        guard let label = CorrectionCommand.label(text) else { publish("Use ‘Correction, this is a …’ with one object label"); return }
        guard let frame = anchor, Date().timeIntervalSince(frame.date) < 12 else { publish("No recent matching frame; repeat while camera is running"); return }
        guard let detection = CorrectionCommand.association(frame.detections) else { publish("Correction not saved: aim at one detected object, then repeat"); return }
        do {
            let queued = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.hasDirectoryPath }
            guard queued.count < 20 else { publish("Correction queue full; stop camera to upload"); return }
            let id = UUID(), prefix = "corrections/\(id.uuidString.lowercased())/"
            let record = HumanTeacherCorrection(id: id, capturedAt: frame.date, transcriptText: text,
                originalDetection: .init(label: detection.label, confidence: Double(detection.confidence), boundingBox: .init(x: detection.bounds.minX, y: detection.bounds.minY, width: detection.bounds.width, height: detection.bounds.height)),
                modelVersion: frame.version, frameObjectKey: prefix + "frame.jpg", correctedLabel: label,
                triggeredAt: Date(), source: frame.source, frameSHA256: SHA256.hash(data: frame.jpeg).map { String(format: "%02x", $0) }.joined())
            let folder = directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try frame.jpeg.write(to: folder.appendingPathComponent("frame.jpg"), options: [.atomic, .completeFileProtection])
            try record.encodedJSON().write(to: folder.appendingPathComponent("correction.json"), options: [.atomic, .completeFileProtection])
            publish("Correction saved: \(label). Upload waits until camera stops. No audio saved.")
            DispatchQueue.main.async { [weak self] in
                self?.lastSaved = "Saved correction: " + label
                self?.saveDiagnostics()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: "Correction saved: " + label) }
            }
        } catch { publish("Correction could not be saved; retry while aiming at one object") }
    }
    #if DEBUG
    func captureFixtureForTest(completion: @escaping @Sendable () -> Void) {
        lock.withLock { accepting = true; active = true }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { completion(); return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        offer(buffer, detections: [Detection(label: "laptop", confidence: 0.9, bounds: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))], modelVersion: "synthetic-test", source: "iPhone camera")
        let utterance = lock.withLock { speechLease }
        acceptTranscript("Correction, this is a piano", final: false, receivedAt: Date(), lease: lock.withLock { epoch }, utterance: utterance, restartAfterCapture: false)
        work.asyncAfter(deadline: .now() + 1.5) { completion() }
    }
    #endif
    private var idle: Bool { lock.withLock { foreground && !active } }
    private func uploadPending() {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.hasDirectoryPath {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            if let created, Date().timeIntervalSince(created) > 86400 { try? FileManager.default.removeItem(at: folder); continue }
            let file = folder.appendingPathComponent("correction.json")
            guard let data = try? Data(contentsOf: file) else { continue }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let record = try? decoder.decode(HumanTeacherCorrection.self, from: data) else { continue }
            if Date().timeIntervalSince(record.capturedAt) > 86400 { try? FileManager.default.removeItem(at: folder); continue }
            guard idle else { continue }
            guard let connection else { publish("Correction queued — teacher connection missing"); return }
            let retryURL = folder.appendingPathComponent("retry.json")
            var retry = (try? JSONDecoder().decode(CorrectionRetry.self, from: Data(contentsOf: retryURL))) ?? CorrectionRetry()
            guard retry.ready(now: Date(), idle: idle) else { continue }
            do {
                let image = try Data(contentsOf: folder.appendingPathComponent("frame.jpg"))
                let ticketBody = try JSONSerialization.data(withJSONObject: ["correction": JSONSerialization.jsonObject(with: data), "image_size": image.count])
                let ticketData = try send(connection, path: "/corrections", body: ticketBody)
                let ticket = try JSONDecoder().decode(CorrectionTicket.self, from: ticketData)
                guard idle else { return }
                guard let url = URL(string: ticket.url), url.scheme == "https", url.host?.hasSuffix(".amazonaws.com") == true else { throw URLError(.badURL) }
                var upload = URLRequest(url: url); upload.httpMethod = "PUT"; upload.httpBody = image
                for (key, value) in ticket.headers { upload.setValue(value, forHTTPHeaderField: key) }
                let (_, code) = try execute(upload)
                guard (200..<300).contains(code) || code == 412 else { throw URLError(.badServerResponse) }
                guard idle else { return }
                _ = try send(connection, path: "/corrections/\(record.id.uuidString.lowercased())/complete", body: Data("{}".utf8))
                try FileManager.default.removeItem(at: folder)
                publish("Correction uploaded — awaiting Nova validation; no model changed")
            } catch {
                retry.failed(now: Date()); if let data = try? JSONEncoder().encode(retry) { try? data.write(to: retryURL, options: [.atomic, .completeFileProtection]) }
                publish("Correction queued — upload retry pending (Wi-Fi, app idle)")
            }
        }
    }
    private func send(_ connection: TeacherConnection, path: String, body: Data) throws -> Data {
        guard let url = URL(string: connection.endpoint + path), url.scheme == "https", url.host?.hasSuffix(".execute-api.eu-west-2.amazonaws.com") == true else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, code) = try execute(request); guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }; return data
    }
    private func execute(_ request: URLRequest) throws -> (Data, Int) {
        let semaphore = DispatchSemaphore(value: 0), result = CorrectionNetworkResult()
        let task = network.dataTask(with: request) { data, response, error in result.data = data; result.code = (response as? HTTPURLResponse)?.statusCode; result.error = error; semaphore.signal() }
        task.resume(); guard semaphore.wait(timeout: .now() + 50) == .success else { task.cancel(); throw URLError(.timedOut) }
        if let error = result.error { throw error }; return (result.data ?? Data(), result.code ?? 0)
    }
}
private struct CorrectionTicket: Decodable { let url: String; let headers: [String: String] }
private final class CorrectionNetworkResult: @unchecked Sendable { var data: Data?; var code: Int?; var error: Error? }
