import SwiftUI
import AVFoundation

struct CameraScreen: View {
    @StateObject private var engine = CameraEngine()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("I See You").font(.largeTitle.bold())
                Text("OBJECT DETECTION • RESEARCH POC").font(.caption.bold()).foregroundStyle(.secondary)
                Button(engine.starting ? "Cancel camera startup" : (engine.running ? "Stop camera" : "Start camera")) {
                    if engine.running || engine.starting { engine.stop() } else { engine.start() }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("cameraToggle")
                if engine.denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Text(engine.status).font(.callout).accessibilityIdentifier("cameraStatus")
                Text("Received video frames: \(engine.receivedFrames)").font(.caption.monospacedDigit()).accessibilityIdentifier("cameraFrames")
                ZStack {
                    CameraPreview(session: engine.session)
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
                                    Text("\(detection.label) \(Int(detection.confidence * 100))%")
                                        .font(.caption2.bold()).padding(3).background(.black.opacity(0.8)).foregroundStyle(.white)
                                }
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }.clipped().accessibilityHidden(true)
                }
                // Portrait 720p buffers and aspect-fit preview share exactly the same rectangle.
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
                if engine.running && engine.fps > 0 {
                    let central = Set(engine.detections.filter(\.inPath).map(\.label)).sorted()
                    Text(central.isEmpty ? "No supported objects detected in centre" : "Central objects: " + central.joined(separator: ", "))
                        .font(.callout.bold())
                }
                HStack {
                    metric("FPS", String(format: "%.1f", engine.fps))
                    metric("Inference", String(format: "%.0f ms", engine.inferenceMS))
                    metric("Frame age", String(format: "%.0f ms", engine.frameAgeMS))
                }
                Text("Thermal: \(engine.thermal) • Distance: unavailable / uncalibrated").font(.caption)
                Text("Central 40% is an approximate image region, not a predicted walking path. Orange boxes overlap it. Detection does not establish whether an object is hazardous.").font(.caption).foregroundStyle(.secondary)
                Text("Confidence: \(Int(engine.confidence * 100))%")
                Slider(value: $engine.confidence, in: 0.1...0.9, step: 0.05).accessibilityLabel("Detection confidence")
                Button("Test voice") { engine.testVoice() }.buttonStyle(.bordered)
                Toggle("Speak object descriptions (preview)", isOn: $engine.detectionVoiceEnabled)
                Text("Preview says, for example, ‘chair in front of the camera’. It describes supported objects in the candidate image region, not verified hazards or safe walking space. Speech starts after repeated observations and repeats at most every eight seconds.").font(.caption)
                Toggle("Spoken hazard warnings (awaiting validated sensing)", isOn: $engine.speechEnabled)
                Picker("Warning sensitivity", selection: $engine.sensitivity) {
                    ForEach(WarningSensitivity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Hazard decision debug", isOn: $engine.showHazardDebug)
                Text("Candidate corridor is uncalibrated. Pose, walking and floor contact are unverified; live speech abstains until validated sensing is integrated. Surface hazards are unavailable.").font(.caption)
                if engine.showHazardDebug {
                    Text("Cyan trapezoid: uncertain candidate corridor").font(.caption)
                    Text(engine.alertStatus).accessibilityIdentifier("hazardStatus")
                    ForEach(engine.hazardDecisions, id: \.detection.id) { decision in
                        Text("\(decision.detection.label) \(Int(decision.detection.confidence * 100))%: \(decision.rationale)")
                            .font(.caption)
                    }
                }
                Text("Frames stay on this iPhone. Nothing is recorded or uploaded.").font(.footnote)
                Text("Experimental prototype. Not a mobility aid or collision-avoidance system. Do not use for road crossing or navigation, or replace a white cane, guide dog, or human assistance.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding()
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
        VStack(alignment: .leading) { Text(name).font(.caption); Text(value).font(.headline.monospacedDigit()) }
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

