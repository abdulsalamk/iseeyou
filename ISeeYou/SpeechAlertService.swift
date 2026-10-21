import AVFoundation

protocol SpeechAlerting: AnyObject {
    func speak(_ alert: SpokenAlert)
    func cancel()
}

// Used exclusively on the main thread. Never queues a backlog of stale guidance.
final class SpeechAlertService: NSObject, SpeechAlerting, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var requiresBluetoothOutput = false
    var onStatus: ((String) -> Void)?
    override init() {
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ alert: SpokenAlert) {
        if alert.level == .urgent { cancel() }
        guard !synthesizer.isSpeaking else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
            if requiresBluetoothOutput && !audio.currentRoute.outputs.contains(where: {
                [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
            }) {
                report("Select your glasses in Audio output before speaking.")
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                return
            }
            synthesizer.usesApplicationAudioSession = true
            let utterance = AVSpeechUtterance(string: alert.message)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
            report("Voice requested · volume \(Int(audio.outputVolume * 100))% · " + audio.currentRoute.outputs.map(\.portName).joined(separator: ", "))
            synthesizer.speak(utterance)
        } catch { report("Voice could not start: " + error.localizedDescription) }
    }
    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func report(_ text: String) {
        #if DEBUG
        print("[ISeeYou.Voice] " + text)
        #endif
        DispatchQueue.main.async { self.onStatus?(text) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        report("Voice speaking")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        report("Voice finished")
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report("Voice cancelled")
    }
}

final class HazardAlertController {
    private var policy: any AlertPolicyApplying
    private let speech: any SpeechAlerting
    private var interruptionObserver: NSObjectProtocol?
    private var interrupted = false
    private var wasEnabled = false
    var requiresBluetoothOutput: Bool {
        get { (speech as? SpeechAlertService)?.requiresBluetoothOutput ?? false }
        set { (speech as? SpeechAlertService)?.requiresBluetoothOutput = newValue }
    }
    var statusChanged: ((String) -> Void)?
    init(policy: any AlertPolicyApplying = AlertPolicy(), speech: any SpeechAlerting = SpeechAlertService()) {
        self.policy = policy
        self.speech = speech
        if let service = speech as? SpeechAlertService {
            service.onStatus = { [weak self] status in self?.statusChanged?(status) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            self.interrupted = raw != AVAudioSession.InterruptionType.ended.rawValue
            self.reset()
        }
    }
    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }
    func update(_ decisions: [HazardDecision], at time: TimeInterval, enabled: Bool) {
        guard enabled, !interrupted else {
            policy.reset()
            // Cancel once when live speech is disabled, not on every camera
            // frame. Explicit Test Voice must survive disabled live updates.
            if wasEnabled { speech.cancel() }
            wasEnabled = false
            return
        }
        wasEnabled = true
        if let alert = policy.update(decisions, at: time) { speech.speak(alert) }
    }
    // Explicit detection-preview mode: describes image position, never hazard risk.
    func preview(_ detections: [Detection], at time: TimeInterval, distanceScale: Double? = nil, minimumConfidence: Float = 0.4) {
        let decisions = detections.filter { $0.confidence >= minimumConfidence && CandidateCorridor.intersectsFoot($0.bounds) }
            .map { $0.conservativelyNamed() }
            .compactMap { detection -> HazardDecision? in
                guard let reading = detection.distance else { return nil }
                let metres = reading.metres * (distanceScale ?? 1)
                guard metres.isFinite, (0.15...5).contains(metres) else { return nil }
                let message = "\(detection.label), approximately " + String(format: "%.1f", metres) + " metres" + (metres < 0.5 ? ", very close" : "")
                return HazardDecision(detection: detection, level: .caution,
                    rationale: "Object description only; risk unverified",
                    message: message)
            }
        update(decisions, at: time, enabled: true)
    }
    func testVoice() {
        guard !interrupted else { return }
        reset()
        speech.speak(SpokenAlert(level: .caution, message: "Voice is working. Object descriptions do not confirm hazards."))
    }
    func reset() { wasEnabled = false; policy.reset(); speech.cancel() }
}
