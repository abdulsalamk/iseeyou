import AVFoundation
import Vision
import CoreML
import Combine
import UIKit
import CoreImage

enum CaptureSource: String, CaseIterable {
    case phone = "iPhone camera"
    case glasses = "Meta glasses"
}

// All session, model and inference operations are serialized off the main thread.
final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published var cameraSource: CaptureSource = .phone {
        didSet {
            guard cameraSource != oldValue else { return }
            stop(reason: "Camera source changed. Tap Start when ready.")
            alerts.requiresBluetoothOutput = cameraSource == .glasses
        }
    }
    @Published private(set) var glassesStatus = "Connect glasses in Developer Mode for this development build."
    @Published private(set) var glassesPreview: UIImage?
    @Published private(set) var previewAspectRatio = 9.0 / 16.0
    private let glasses = MetaGlassesSource()
    private let externalFrameGate = InferenceFrameGate()
    private let previewContext = CIContext(options: [.cacheIntermediates: false])
    func connectGlasses() { glasses.connect() }
    func allowGlassesCamera() { glasses.authorizeCamera() }
    func handleGlassesCallback(_ url: URL) { glasses.handleCallback(url) }
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
    @Published private(set) var voiceStatus = "Voice idle"
    func testVoice() { voiceStatus = "Testing voice…"; alerts.testVoice() }
    @Published var sensitivity: WarningSensitivity = .conservative {
        didSet { alerts.reset() }
    }
    @Published var showHazardDebug = true
    @Published var surfaceDescriptionsEnabled = true { didSet { alerts.reset() } }
    @Published private(set) var centralSurface: ObjectDistance?
    @Published private(set) var doorChecking = false
    @Published private(set) var doorStatus = "Door state not checked"
    private var currentDoorCheck: UUID? // main thread
    private var doorRequest: UUID? // inference queue
    private var doorLastInference: TimeInterval = -.infinity
    private var doorConsensus = DoorStateConsensus()
    private var doorClassifier: DoorSceneClassifier?

    func checkDoorState() {
        guard running, wantsRunning else { doorStatus = "Start the camera before checking a door."; return }
        let token = UUID(), lease = generation
        currentDoorCheck = token; doorChecking = true
        doorStatus = "Checking centre view. Hold still, aimed at one door."
        inferenceQueue.async { [self] in
            guard generation == lease else { return }
            doorRequest = token; doorLastInference = -.infinity; doorConsensus = DoorStateConsensus()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.finishDoorCheck(.uncertain, token: token, lease: lease)
        }
    }

    private func finishDoorCheck(_ state: DoorVisualState, token: UUID, lease: UUID) {
        guard currentDoorCheck == token, generation == lease, running, wantsRunning else { return }
        currentDoorCheck = nil; doorChecking = false
        doorStatus = state.message + " Experimental scene estimate."
        alerts.speakDoorAssessment(state)
        inferenceQueue.async { [self] in if doorRequest == token { doorRequest = nil } }
    }

    private func processDoorCheck(_ buffer: CVPixelBuffer, sample: CMSampleBuffer, external: Bool,
                                  receivedAt: TimeInterval?, lease: UUID) {
        guard let token = doorRequest, generation == lease,
              CACurrentMediaTime() - doorLastInference >= 0.35 else { return }
        doorLastInference = CACurrentMediaTime()
        do {
            if doorClassifier == nil { doorClassifier = try DoorSceneClassifier() }
            guard let doorClassifier else { return }
            let state = try doorClassifier.assess(buffer)
            let age = external ? CACurrentMediaTime() - (receivedAt ?? -.infinity)
                : CMClockGetTime(CMClockGetHostTimeClock()).seconds - CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Never carry a stale or queued image into a spoken door result.
            guard age.isFinite, age >= -0.05, age <= 1 else { doorConsensus = DoorStateConsensus(); return }
            guard let stable = doorConsensus.update(state, at: CACurrentMediaTime()) else { return }
            doorRequest = nil
            DispatchQueue.main.async { [weak self] in self?.finishDoorCheck(stable, token: token, lease: lease) }
        } catch {
            cameraLog("Door check unavailable: " + error.localizedDescription)
            doorRequest = nil
            DispatchQueue.main.async { [weak self] in self?.finishDoorCheck(.uncertain, token: token, lease: lease) }
        }
    }
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
    private let visibilityLock = NSLock()
    private var foreground = true
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var distanceStatus = "Distance: awaiting camera"
    @Published private(set) var lastDistanceFrame = Date.distantPast
    private var calibrationProfile = CalibrationProfile()
    func setCalibration(_ profile: CalibrationProfile) {
        if calibrationProfile.scale != profile.scale { alerts.reset() }
        calibrationProfile = profile
    }
    private var depthEstimator: MetricDepthEstimator?
    private var request: VNCoreMLRequest?
    private var configured = false
    private var wantsRunning = false // main-thread only
    private var imageLogGeneration: UUID?
    private var imageLogCount = 0
    private var frameCount = 0
    private var windowStart = CACurrentMediaTime()

    override init() {
        super.init()
        glasses.onSetupStatus = { [weak self] message in self?.glassesStatus = message }
        alerts.statusChanged = { [weak self] status in self?.voiceStatus = status }
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
        visibilityLock.withLock { foreground = active }
        if cameraSource == .glasses { GlassesSessionDiagnostics.record(["foreground": active, "background": background]) }
        // The iOS permission alert makes the scene inactive. Preserve that
        // explicit start request; a real background transition still cancels it.
        if CameraLifecyclePolicy.shouldStop(active: active, background: background, permissionPending: permissionPending,
                                            glassesSessionRequested: cameraSource == .glasses && wantsRunning) {
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
        status = cameraSource == .phone ? "Starting rear camera…" : "Starting Meta glasses camera…"
        generation = UUID()
        if cameraSource == .glasses { launchGlasses(); return }
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

    private func launchGlasses() {
        let lease = generation
        do { try alerts.beginGlassesAudio() }
        catch { stop(reason: "Cannot start glasses audio: " + error.localizedDescription); return }
        inferenceQueue.async { [self] in
            guard generation == lease else { return }
            do {
                if request == nil { try loadModel() }
                if depthEstimator == nil { depthEstimator = try MetricDepthEstimator() }
            } catch {
                cameraLog("Glasses model preparation: " + error.localizedDescription)
            }
            frameCount = 0; windowStart = CACurrentMediaTime()
            DispatchQueue.main.async {
                guard self.wantsRunning, self.generation == lease else { return }
                self.glasses.start(onFrame: { [weak self] sample, receivedAt in
                    self?.enqueueGlassesFrame(sample, lease: lease, receivedAt: receivedAt)
                }, onState: { [weak self] active, message in
                    guard let self, self.generation == lease else { return }
                    if !active { self.stop(reason: message); return }
                    self.running = true; self.starting = false; self.status = message
                })
            }
        }
    }
    private func enqueueGlassesFrame(_ sample: CMSampleBuffer, lease: UUID, receivedAt: TimeInterval) {
        guard generation == lease, externalFrameGate.begin() else { return }
        inferenceQueue.async { [self] in
            defer { externalFrameGate.end() }
            guard generation == lease else { return }
            processFrame(sample, lease: lease, external: true, receivedAt: receivedAt)
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
        previewAspectRatio = 9.0 / 16.0
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
                    do {
                        if depthEstimator == nil { depthEstimator = try MetricDepthEstimator() }
                        DispatchQueue.main.async {
                            guard self.generation == lease else { return }
                            self.distanceStatus = "Indoor distance estimates · unverified"
                        }
                    } catch {
                        let message = "Distance unavailable: " + error.localizedDescription
                        DispatchQueue.main.async {
                            guard self.generation == lease else { return }
                            self.distanceStatus = message
                        }
                    }
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
        config.computeUnits = .cpuAndNeuralEngine
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
        glasses.stop()
        glassesPreview = nil
        previewAspectRatio = 9.0 / 16.0
        detections = []
        centralSurface = nil
        currentDoorCheck = nil; doorChecking = false; doorStatus = "Door state not checked"
        lastDistanceFrame = .distantPast
        distanceStatus = "Distance: camera stopped"
        hazardDecisions = []
        alertStatus = "Stopped; pending speech cancelled"
        alerts.reset()
        alerts.endGlassesAudio()
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
        processFrame(sampleBuffer, lease: generation, external: false)
    }
    private func processFrame(_ sampleBuffer: CMSampleBuffer, lease: UUID, external: Bool, receivedAt: TimeInterval? = nil) {
        guard generation == lease, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if external && visibilityLock.withLock({ foreground }) {
            let image = CIImage(cvPixelBuffer: buffer)
            let preview = previewContext.createCGImage(image, from: image.extent).map { UIImage(cgImage: $0) }
            let ratio = Double(CVPixelBufferGetWidth(buffer)) / Double(CVPixelBufferGetHeight(buffer))
            DispatchQueue.main.async {
                guard self.appActive, self.wantsRunning, self.generation == lease else { return }
                self.glassesPreview = preview; self.previewAspectRatio = ratio
            }
        }
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
            var results = observations.compactMap { observation -> Detection? in
                guard let label = observation.labels.first else { return nil }
                return Detection(label: label.identifier, confidence: label.confidence, bounds: observation.boundingBox)
            }
            var depthError: String?
            var surface: ObjectDistance?
            if let depthEstimator {
                do {
                    let estimate = try depthEstimator.estimateFrame(buffer, detections: results)
                    results = estimate.objects; surface = estimate.surface
                }
                catch { depthError = error.localizedDescription }
            }
            let depthAvailable = depthEstimator != nil
            let end = CACurrentMediaTime()
            #if DEBUG
            if imageLogCount % 30 == 0 {
                let readings = results.compactMap { item in item.distance.map { String(format: "%@ raw %.2f m", item.label, $0.metres) } }
                cameraLog("Depth inference total \((end-start)*1000) ms; " + readings.prefix(4).joined(separator: "; "))
            }
            #endif
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let hostAge = CMClockGetTime(CMClockGetHostTimeClock()).seconds - timestamp
            // DAT timestamps are not in the iPhone host clock domain. For
            // experimental descriptions measure local delivery-to-result time;
            // this does not establish glasses capture or transport latency.
            let age: Double
            if external, let receivedAt {
                age = max(0, end - receivedAt) * 1000
            } else {
                age = timestamp.isFinite && hostAge >= -0.05 ? max(0, hostAge) * 1000 : Double.infinity
            }
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
                results = results.map { $0.conservativelyNamed() }
                // No validated pose, motion or ground-contact provider ships yet.
                // Explicit unknown evidence makes this baseline abstain from speech.
                self.hazardDecisions = self.assessor.assess(results, context: HazardContext(), sensitivity: self.sensitivity)
                let stale = age > 500 || CACurrentMediaTime() - end > 0.5
                if self.detectionVoiceEnabled {
                    self.alerts.preview(stale ? [] : results, at: CACurrentMediaTime(), distanceScale: self.calibrationProfile.scale, minimumConfidence: Float(self.confidence),
                        surface: !stale && self.surfaceDescriptionsEnabled ? surface : nil)
                    self.alertStatus = stale ? "Suppressed: stale frame" : "Experimental spoken distance estimates; accuracy unverified"
                } else {
                    self.alerts.update(stale ? [] : self.hazardDecisions, at: CACurrentMediaTime(), enabled: self.speechEnabled)
                    self.alertStatus = stale ? "Suppressed: stale frame" : (self.speechEnabled ? "Suppressed: geometry unverified" : "Speech off")
                }
                if stale {
                    results = results.map { item in var copy = item; copy.distance = nil; return copy }
                }
                self.lastDistanceFrame = Date()
                self.centralSurface = !stale && self.surfaceDescriptionsEnabled ? surface : nil
                if let depthError { self.distanceStatus = "Distance unavailable: " + depthError }
                else if depthAvailable {
                    self.distanceStatus = stale ? "Distance unavailable: stale frame" : "Indoor distance estimates · " + (self.calibrationProfile.passed ? "bench checks passed" : "unverified / needs calibration")
                }
                self.detections = results.filter { $0.confidence >= Float(self.confidence) }
                self.inferenceMS = (end - start) * 1000
                self.frameAgeMS = age
                self.fps = rate
                self.thermal = heat
            }
            processDoorCheck(buffer, sample: sampleBuffer, external: external, receivedAt: receivedAt, lease: lease)
        } catch {
            DispatchQueue.main.async {
                guard self.generation == lease else { return }
                self.alerts.reset(); self.hazardDecisions = []; self.detections = []; self.centralSurface = nil; self.status = "Inference failed: \(error.localizedDescription)" }
        }
    }
}

private enum CameraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

