import AVFoundation
import Vision
import CoreML
import Combine
import UIKit

// All session, model and inference operations are serialized off the main thread.
final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "iseeyou.camera", qos: .userInitiated)
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var denied = false
    @Published private(set) var running = false
    @Published private(set) var inferenceMS = 0.0
    @Published private(set) var frameAgeMS = 0.0
    @Published private(set) var fps = 0.0
    @Published private(set) var thermal = "Unknown"
    @Published var confidence: Double = 0.4
    @Published var speechEnabled = false {
        didSet {
            if speechEnabled { detectionVoiceEnabled = false }
            alerts.reset()
        }
    }
    @Published var detectionVoiceEnabled = false {
        didSet {
            if detectionVoiceEnabled { speechEnabled = false }
            alerts.reset()
        }
    }
    func testVoice() { alerts.testVoice() }
    @Published var sensitivity: WarningSensitivity = .conservative {
        didSet { alerts.reset() }
    }
    @Published var showHazardDebug = true
    @Published private(set) var hazardDecisions: [HazardDecision] = []
    @Published private(set) var alertStatus = "Speech off"
    private let assessor: any HazardAssessing = HazardAssessment()
    private let alerts = HazardAlertController()
    private var generation = UUID() // main-thread lifecycle lease
    private var request: VNCoreMLRequest?
    private var configured = false
    private var wantsRunning = false // main-thread only
    private var frameCount = 0
    private var windowStart = CACurrentMediaTime()

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        generation = UUID()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: launch()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning else { return }
                    if granted { self.launch() } else { self.deny() }
                }
            }
        default: deny()
        }
    }

    private func deny() {
        wantsRunning = false
        denied = true
        status = "Camera access denied. Enable it in Settings."
    }

    private func launch() {
        denied = false
        let lease = generation
        queue.async { [self] in
            do {
                if !configured { try configure() }
                if request == nil { try loadModel() }
                session.startRunning()
                frameCount = 0
                windowStart = CACurrentMediaTime()
                DispatchQueue.main.async {
                    guard self.wantsRunning, self.generation == lease else { return }
                    self.running = true
                    self.status = self.request == nil
                        ? "Preview only — add yolo11n.mlpackage (see README)."
                        : "Local object detection active • distance unavailable"
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.generation == lease else { return }
                    self.wantsRunning = false
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.message("Rear camera unavailable. Use a physical iPhone.")
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.message("Cannot add rear camera.") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.message("Cannot configure camera frames.")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
        // Physically rotate buffers to portrait; Vision receives .up.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        configured = true
    }

    private func loadModel() throws {
        guard let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config)))
        request?.imageCropAndScaleOption = .scaleFill
    }

    func stop() {
        wantsRunning = false
        generation = UUID()
        running = false
        detections = []
        hazardDecisions = []
        alertStatus = "Stopped; pending speech cancelled"
        alerts.reset()
        let lease = generation
        queue.async { [self] in
            session.stopRunning()
            DispatchQueue.main.async {
                guard self.generation == lease else { return }
                self.running = false
                self.detections = []
                self.fps = 0
                self.status = "Camera stopped"
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let request, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let lease = DispatchQueue.main.sync { self.generation }
        let start = CACurrentMediaTime()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
            guard let observations = request.results as? [VNRecognizedObjectObservation] else {
                DispatchQueue.main.async {
                    guard self.generation == lease else { return }
                    self.alerts.reset()
                    self.hazardDecisions = []
                    self.detections = []
                    self.status = "Unsupported model outputs. Export YOLO11n with nms=True."
                }
                return
            }
            let results = observations.compactMap { observation -> Detection? in
                guard let label = observation.labels.first else { return nil }
                return Detection(label: label.identifier, confidence: label.confidence, bounds: observation.boundingBox)
            }
            let end = CACurrentMediaTime()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let age = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - timestamp) * 1000
            frameCount += 1
            let elapsed = end - windowStart
            let rate = Double(frameCount) / max(elapsed, 0.001)
            if elapsed >= 1 { frameCount = 0; windowStart = end }
            let heat: String
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: heat = "Nominal"
            case .fair: heat = "Fair"
            case .serious: heat = "Serious"
            case .critical: heat = "Critical"
            @unknown default: heat = "Unknown"
            }
            DispatchQueue.main.async {
                guard self.running, self.wantsRunning, self.generation == lease else { return }
                // No validated pose, motion or ground-contact provider ships yet.
                // Explicit unknown evidence makes this baseline abstain from speech.
                self.hazardDecisions = self.assessor.assess(results, context: HazardContext(), sensitivity: self.sensitivity)
                let stale = age > 500 || CACurrentMediaTime() - end > 0.5
                if self.detectionVoiceEnabled {
                    self.alerts.preview(stale ? [] : results, at: CACurrentMediaTime())
                    self.alertStatus = stale ? "Suppressed: stale frame" : "Object voice preview active; hazard risk unverified"
                } else {
                    self.alerts.update(stale ? [] : self.hazardDecisions, at: CACurrentMediaTime(), enabled: self.speechEnabled)
                    self.alertStatus = stale ? "Suppressed: stale frame" : (self.speechEnabled ? "Suppressed: geometry unverified" : "Speech off")
                }
                self.detections = results.filter { $0.confidence >= Float(self.confidence) }
                self.inferenceMS = (end - start) * 1000
                self.frameAgeMS = age
                self.fps = rate
                self.thermal = heat
            }
        } catch {
            DispatchQueue.main.async {
                guard self.generation == lease else { return }
                self.alerts.reset(); self.hazardDecisions = []; self.detections = []; self.status = "Inference failed: \(error.localizedDescription)" }
        }
    }
}

private enum CameraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

