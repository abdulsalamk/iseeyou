import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var calibration = DistanceCalibration()
    @StateObject private var glassesCalibration = DistanceCalibration(url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("distance-calibration-glasses.json"))
    private var activeCalibration: DistanceCalibration { engine.cameraSource == .glasses ? glassesCalibration : calibration }
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("I See You").font(.largeTitle.bold())
                Text("OBJECT DETECTION • RESEARCH POC").font(.caption.bold()).foregroundStyle(.secondary)
                BackgroundTeacherPanel(teacher: engine.teacher)
                Picker("Camera source", selection: $engine.cameraSource) {
                    ForEach(CaptureSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if engine.cameraSource == .glasses {
                    Button("Connect Meta glasses") { engine.connectGlasses() }
                    Button("Allow glasses camera") { engine.allowGlassesCamera() }
                    TwoLineExplanation(text: engine.glassesStatus).font(.caption)
                    Text("Wear and open your glasses. Developer Mode is required. Once started, glasses camera and speech can continue with the phone locked. Unlock and tap Stop camera to end the session.").font(.caption)
                }
                Button(engine.starting ? "Cancel camera startup" : (engine.running ? "Stop camera" : "Start camera")) {
                    if engine.running || engine.starting { engine.stop(endTeacherSession: true) } else { engine.start() }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("cameraToggle")
                if engine.denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                HStack {
                    Text("Voice output: choose a Bluetooth device or speaker").font(.caption)
                    AudioOutputPicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Choose voice audio output")
                        .accessibilityIdentifier("voiceAudioOutput")
                }
                Button("Test voice") { engine.testVoice() }.buttonStyle(.bordered).accessibilityIdentifier("testVoice")
                Toggle("Speak estimated distances (experimental)", isOn: $engine.detectionVoiceEnabled)
                Toggle("Describe nearby surfaces (experimental)", isOn: $engine.surfaceDescriptionsEnabled)
                TwoLineExplanation(text: engine.centralSurface.map {
                    String(format: "Central surface ~%.1f m (unverified)", $0.metres * (activeCalibration.profile.scale ?? 1))
                } ?? "Central surface: no consistent nearby depth patch").font(.caption)
                Text("Surface descriptions use central depth without recognising a wall or door. Hold the camera level. They do not establish a clear path or detect glass reliably.").font(.caption)
                Button(engine.doorChecking ? "Checking door…" : "Check and speak door state") { engine.checkDoorState() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(engine.doorChecking)
                    .accessibilityIdentifier("checkDoorState")
                TwoLineExplanation(text: engine.running
                    ? "Aim at one door, hold still, then tap the blue check button."
                    : "Camera stopped. Tap Start camera before checking a door.").font(.caption)
                TwoLineExplanation(text: engine.doorStatus).font(.caption)
                    .accessibilityIdentifier("doorCheckStatus")
                DisclosureGroup("Door-check details (experimental)") {
                    Text("Aim the centre of the camera at one door and hold still. This compares the scene with descriptions; it does not locate the door, measure its opening, or determine whether it is locked.").font(.caption)
                    Text("Spoken states are tentative and unverified. An apparent open door does not establish a safe passage.").font(.caption)
                    Text(engine.doorDiagnostic).font(.caption.monospacedDigit())
                    ShareLink("Share door-check diagnostics", item: engine.doorStatus + "\n" + engine.doorDiagnostic)
                }
                TwoLineExplanation(text: engine.voiceStatus).font(.caption).accessibilityIdentifier("voiceStatus")
                TwoLineExplanation(text: engine.status).font(.callout).accessibilityIdentifier("cameraStatus")
                DisclosureGroup("Detector updates") {
                    Text(engine.detectorStatus).font(.caption)
                    Button("Check for signed model update") { engine.teacher.checkForModelUpdate() }
                    Text(engine.teacher.modelUpdateStatus).font(.caption)
                    Button("Install reviewed model update") { engine.updateDetector() }
                        .disabled(engine.running || engine.starting || engine.modelUpdateBusy)
                    Button("Use bundled YOLO26 detector") { engine.updateDetector(useBundled: true) }
                        .disabled(engine.running || engine.starting || engine.modelUpdateBusy)
                    Text("Updates download over Wi-Fi into a staging area. Stop the camera to install; the signature, checksums and Core ML output are verified first. Later camera samples feed Nova comparisons. Restore the previous app build to return to YOLO11.").font(.caption)
                }
                Text("Received video frames: \(engine.receivedFrames)").font(.caption.monospacedDigit()).accessibilityIdentifier("cameraFrames")
                ZStack {
                    if engine.cameraSource == .phone { CameraPreview(session: engine.session) }
                    else if let image = engine.glassesPreview { Image(uiImage: image).resizable().scaledToFit() }
                    else { Color.black }
                    GeometryReader { proxy in
                        Rectangle().fill(.yellow.opacity(0.1))
                            .overlay(Rectangle().stroke(.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6])))
                            .frame(width: proxy.size.width * 0.4)
                            .offset(x: proxy.size.width * 0.3)
                        if engine.showHazardDebug {
                            Path { path in
                                let w = proxy.size.width, h = proxy.size.height
                                path.move(to: CGPoint(x: w * 0.18, y: h))
                                path.addLine(to: CGPoint(x: w * 0.40, y: h * 0.45))
                                path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.45))
                                path.addLine(to: CGPoint(x: w * 0.82, y: h))
                                path.closeSubpath()
                            }.stroke(.cyan, style: StrokeStyle(lineWidth: 2, dash: [4]))
                        }
                        ForEach(engine.detections) { detection in
                            let rect = DetectionGeometry.displayRect(detection.bounds, in: proxy.size)
                            Rectangle().stroke(detection.inPath ? .orange : .green, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .overlay(alignment: .topLeading) {
                                    Text("\(detection.label) · confidence \(Int(detection.confidence * 100))%" + (detection.distance.map {
                                        String(format: "\n~%.1f m (unverified)", $0.metres * (activeCalibration.profile.scale ?? 1))
                                    } ?? "\nDistance unavailable"))
                                        .font(.caption2.bold()).padding(3).background(.black.opacity(0.8)).foregroundStyle(.white)
                                }
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }.clipped().accessibilityHidden(true)
                }
                // Portrait 720p buffers and aspect-fit preview share exactly the same rectangle.
                .aspectRatio(engine.previewAspectRatio, contentMode: .fit)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                let central = Set(engine.detections.filter(\.inPath).map(\.label)).sorted()
                TwoLineExplanation(text: engine.running && engine.fps > 0
                    ? (central.isEmpty ? "No supported objects detected in centre" : "Central objects: " + central.joined(separator: ", "))
                    : "Central objects: waiting for camera frames")
                    .font(.callout.bold())
                HStack {
                    metric("FPS", String(format: "%.1f", engine.fps))
                    metric("Inference", String(format: "%.0f ms", engine.inferenceMS))
                    metric(engine.cameraSource == .glasses ? "Since delivery" : "Frame age", String(format: "%.0f ms", engine.frameAgeMS))
                }
                Text("Thermal: \(engine.thermal)").font(.caption)
                TwoLineExplanation(text: engine.distanceStatus).font(.caption)
                DisclosureGroup("Measure and validate distances") {
                    DistanceCalibrationView(calibration: activeCalibration, detections: engine.detections,
                        frameAgeMS: engine.frameAgeMS, frameDate: engine.lastDistanceFrame)
                }
                Text("Central 40% is an approximate image region, not a predicted walking path. Orange boxes overlap it. Detection does not establish whether an object is hazardous.").font(.caption).foregroundStyle(.secondary)
                Text("Minimum detection confidence: \(Int(engine.confidence * 100))%")
                Slider(value: $engine.confidence, in: 0.1...0.9, step: 0.05).accessibilityLabel("Detection confidence")
                Text("Below 50% confidence, retained detections are named unknown object on screen and in speech. Detections below the minimum above are hidden.").font(.caption)
                Text("Speech uses the displayed estimate, for example, ‘chair, approximately 1.5 metres’. Estimates are unverified until physically checked. Missing or stale distances are not spoken. Repeated observations are required; speech repeats at most every eight seconds.").font(.caption)
                Toggle("Spoken hazard warnings (awaiting validated sensing)", isOn: $engine.speechEnabled)
                Picker("Warning sensitivity", selection: $engine.sensitivity) {
                    ForEach(WarningSensitivity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Hazard decision debug", isOn: $engine.showHazardDebug)
                Text("Candidate corridor is uncalibrated. Pose, walking and floor contact are unverified; live speech abstains until validated sensing is integrated. Surface hazards are unavailable.").font(.caption)
                if engine.showHazardDebug {
                    Text("Cyan trapezoid: uncertain candidate corridor").font(.caption)
                    TwoLineExplanation(text: engine.alertStatus).accessibilityIdentifier("hazardStatus")
                    DecisionExplanationPanel(explanations: engine.hazardDecisions.map { decision in
                        "\(decision.detection.label) \(Int(decision.detection.confidence * 100))%: \(decision.rationale)"
                    })
                }
                Text(engine.teacher.enabled ? "Teacher sharing is enabled. Sampled clips are uploaded privately; local detection and speech run on this iPhone." : "Teacher sharing is off. No new samples are recorded or uploaded; an in-flight request may finish.").font(.footnote)
                Text("Experimental prototype. Not a mobility aid or collision-avoidance system. Do not use for road crossing or navigation, or replace a white cane, guide dog, or human assistance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }
        .onReceive(calibration.$profile) { if engine.cameraSource == .phone { engine.setCalibration($0) } }
        .onReceive(glassesCalibration.$profile) { if engine.cameraSource == .glasses { engine.setCalibration($0) } }
        .onChange(of: engine.cameraSource) { _, _ in engine.setCalibration(activeCalibration.profile) }
        .onOpenURL { url in
            if url.scheme == "iseeyou", url.host == "learning-mode",
               let value = url.pathComponents.dropFirst().first,
               let mode = BackgroundTeacher.LearningMode(rawValue: value) {
                engine.teacher.learningMode = mode
            } else {
                engine.handleGlassesCallback(url)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            print("[ISeeYou.Camera] scenePhase=\(phase)")
            #endif
            engine.sceneChanged(active: phase == .active, background: phase == .background)
        }
        .onDisappear { engine.stop() }
    }
    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(name).font(.caption).lineLimit(1); Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private var previewObservation: NSKeyValueObservation?
    override init(frame: CGRect) {
        super.init(frame: frame)
        observePreview()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePreview()
    }
    private func observePreview() {
        #if DEBUG
        previewObservation = preview.observe(\.isPreviewing, options: [.initial, .new]) { layer, _ in
            print("[ISeeYou.Camera] preview layer rendering=\(layer.isPreviewing)")
        }
        #endif
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) {}
}


private struct BackgroundTeacherPanel: View {
    @ObservedObject var teacher: BackgroundTeacher
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Background teacher: " + teacher.status, systemImage: teacher.light == .verified ? "checkmark.circle.fill" : "circle.fill")
                .font(.callout.bold()).foregroundStyle(teacher.light.color)
                .accessibilityIdentifier("backgroundTeacherStatus")
            Text(teacher.detail).font(.caption)
            Text(teacher.lastReceipt).font(.caption)
            Picker("Learning path for new sessions", selection: $teacher.learningMode) {
                ForEach(BackgroundTeacher.LearningMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .accessibilityIdentifier("learningModePicker")
            Text(teacher.learningMode == .localMac
                 ? "New sessions upload to a separate private S3 queue for Mac-side review and training. Existing sessions keep their selected route."
                 : "New sessions use the existing Nova and SageMaker workflow, subject to its budget and training quota.")
                .font(.caption)
            Toggle("Share camera samples with the teacher", isOn: $teacher.enabled)
                .accessibilityHint("Opt in to private camera sample uploads over Wi-Fi while the camera is running.")
                .accessibilityIdentifier("teacherSharingToggle")
            DisclosureGroup("What gets shared") {
                Text("When enabled with the camera running, this pilot records three low-rate frames into a silent three-second clip, about once a minute. It uploads the clip, its first image and matching YOLO predictions over Wi-Fi. It never records microphone audio or other apps.")
                Text("Up to four clips wait privately on this phone for up to 24 hours. Uploads retry with a bounded backoff. The server accepts up to 50 new samples per UTC day. Raw media expires after seven days; proposed results after thirty days. Battery overhead is not yet measured. Mock results are not AI analysis or training data.")
                if teacher.learningMode == .localMac {
                    Text("Local Mac + ChatGPT is a routing choice. The Mac queue does not make ChatGPT requests yet; review and training remain an operator-run local workflow until ChatGPT sign-in and usage-limit handling are integrated.")
                    Link("Check ChatGPT plan usage", destination: URL(string: "https://chatgpt.com/#settings/Usage")!)
                }
            }.font(.caption)
        }
        .padding(10).background(.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
