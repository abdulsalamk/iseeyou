import AVFoundation
import Vision
import CoreML
import Combine
import UIKit

// All session, model and inference operations are serialized off the main thread.
final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "iseeyou.camera", qos: .userInitiated)
    private let inferenceQueue = DispatchQueue(label: "iseeyou.inference", qos: .userInitiated)
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var denied = false
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var receivedFrames = 0
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
    private let generationLock = NSLock()
    private var generationValue = UUID()
    private var generation: UUID {
        get { generationLock.withLock { generationValue } }
        set { generationLock.withLock { generationValue = newValue } }
    }
    private var permissionPending = false // main-thread only
    private var appActive = true // main-thread only
    private var observers: [NSObjectProtocol] = []
    private var request: VNCoreMLRequest?
    private var configured = false
    private var wantsRunning = false // main-thread only
    private var imageLogGeneration: UUID?
    private var imageLogCount = 0
    private var frameCount = 0
    private var windowStart = CACurrentMediaTime()

    override init() {
        super.init()
        cameraLog("initial authorization=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.stop(reason: "Camera error: " + (error?.localizedDescription ?? "unknown capture error") + ". Tap Start to retry.")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
            self?.stop(reason: "Camera interrupted (\(reason?.stringValue ?? "unknown")). Close other camera apps and tap Start to retry.")
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func sceneChanged(active: Bool, background: Bool) {
        appActive = active
        // The iOS permission alert makes the scene inactive. Preserve that
        // explicit start request; a real background transition still cancels it.
        if CameraLifecyclePolicy.shouldStop(active: active, background: background, permissionPending: permissionPending) {
            stop(reason: "Camera stopped while app inactive. Tap Start to resume.")
        } else if active, wantsRunning, permissionPending,
                  AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            permissionPending = false
            launch()
        }
    }

    private func cameraLog(_ message: String) {
        #if DEBUG
        print("[ISeeYou.Camera] " + message)
        #endif
    }

    func start() {
        cameraLog("Start tapped; authorization=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue), wantsRunning=\(wantsRunning)")
        guard !wantsRunning else { return }
        wantsRunning = true
        starting = true
        receivedFrames = 0
        status = "Starting rear camera…"
        generation = UUID()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: launch()
        case .notDetermined:
            permissionPending = true
            status = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsRunning, self.permissionPending else { return }
                    if !granted { self.deny() }
                    else if self.appActive {
                        self.permissionPending = false
                        self.launch()
                    } else { self.status = "Camera allowed; waiting for app to become active…" }
                }
            }
        default: deny()
        }
    }

    private func deny() {
        wantsRunning = false
        starting = false
        permissionPending = false
        denied = true
        status = "Camera access denied. Enable it in Settings."
    }

    private func launch() {
        denied = false
        let lease = generation
        queue.async { [self] in
            guard generation == lease else { return }
            do {
                cameraLog("configuring session")
                if !configured { try configure() }
                guard generation == lease else { return }
                cameraLog("calling startRunning before model loading")
                session.startRunning()
                let didStart = session.isRunning
                cameraLog("startRunning returned: running=\(didStart), interrupted=\(session.isInterrupted)")
                DispatchQueue.main.async {
                    guard self.wantsRunning, self.generation == lease else { return }
                    self.starting = false
                    self.running = didStart
                    if !didStart {
                        self.wantsRunning = false
                        self.status = "Camera did not start. Close other camera apps, then retry."
                    } else { self.status = "Camera active · loading object detector…" }
                }
                guard didStart else { return }
                // Model preparation must not block camera start/stop or preview.
                inferenceQueue.async { [self] in
                    guard generation == lease else { return }
                    frameCount = 0
                    windowStart = CACurrentMediaTime()
                    let modelStatus: String
                    do {
                        if request == nil { try loadModel() }
                        modelStatus = request == nil ? "Camera active · preview only (model missing)" : "Camera active · object detection ready"
                    } catch { modelStatus = "Camera active · preview only: detector failed to load: " + error.localizedDescription }
                    cameraLog(modelStatus)
                    DispatchQueue.main.async {
                        guard self.wantsRunning, self.generation == lease else { return }
                        self.status = modelStatus
                    }
                }
            } catch {
                cameraLog("startup failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.generation == lease else { return }
                    self.wantsRunning = false
                    self.starting = false
                    self.running = false
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
        output.setSampleBufferDelegate(self, queue: inferenceQueue)
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

    func stop(reason: String = "Camera stopped") {
        cameraLog("stop requested: " + reason)
        wantsRunning = false
        permissionPending = false
        starting = false
        status = reason
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
            }
        }
    }

    // Numeric brightness diagnostics only: no image is saved or transmitted.
    private func logImageBrightness(_ buffer: CVPixelBuffer) {
        #if DEBUG
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var minimum = 255, maximum = 0, sum = 0, count = 0
        for y in stride(from: 0, to: height, by: max(1, height / 16)) {
            for x in stride(from: 0, to: width, by: max(1, width / 16)) {
                let index = y * rowBytes + x * 4
                let value = (Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2])) / 3
                minimum = min(minimum, value); maximum = max(maximum, value)
                sum += value; count += 1
            }
        }
        cameraLog("frame \(width)x\(height) sampled RGB brightness min=\(minimum), mean=\(sum / max(count, 1)), max=\(maximum)")
        #endif
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let lease = generation
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        #if DEBUG
        if imageLogGeneration != lease { imageLogGeneration = lease; imageLogCount = 0 }
        imageLogCount += 1
        if imageLogCount == 1 || imageLogCount % 60 == 0 { logImageBrightness(buffer) }
        #endif
        DispatchQueue.main.async {
            guard self.wantsRunning, self.generation == lease else { return }
            self.receivedFrames += 1
            if self.receivedFrames == 1 { self.cameraLog("camera delivered first video frame") }
        }
        guard let request else { return }
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

