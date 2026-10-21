import AVFoundation

protocol SpeechAlerting: AnyObject {
    func speak(_ alert: SpokenAlert)
    func cancel()
}

// Used exclusively on the main thread. Never queues a backlog of stale guidance.
final class SpeechAlertService: SpeechAlerting {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ alert: SpokenAlert) {
        if alert.level == .urgent { cancel() }
        guard !synthesizer.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: alert.message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en")
        synthesizer.speak(utterance)
    }
    func cancel() { synthesizer.stopSpeaking(at: .immediate) }
}

final class HazardAlertController {
    private var policy: any AlertPolicyApplying
    private let speech: any SpeechAlerting
    private var interruptionObserver: NSObjectProtocol?
    private var interrupted = false
    init(policy: any AlertPolicyApplying = AlertPolicy(), speech: any SpeechAlerting = SpeechAlertService()) {
        self.policy = policy
        self.speech = speech
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
        guard enabled, !interrupted else { reset(); return }
        if let alert = policy.update(decisions, at: time) { speech.speak(alert) }
    }
    // Explicit detection-preview mode: describes image position, never hazard risk.
    func preview(_ detections: [Detection], at time: TimeInterval) {
        let decisions = detections.filter { $0.confidence >= 0.8 && CandidateCorridor.intersectsFoot($0.bounds) }
            .map { detection in
                HazardDecision(detection: detection, level: .caution,
                    rationale: "Object description only; risk unverified",
                    message: "\(detection.label) in front of the camera")
            }
        update(decisions, at: time, enabled: true)
    }
    func testVoice() {
        guard !interrupted else { return }
        reset()
        speech.speak(SpokenAlert(level: .caution, message: "Voice is working. Object descriptions do not confirm hazards."))
    }
    func reset() { policy.reset(); speech.cancel() }
}
