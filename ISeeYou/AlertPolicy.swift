import Foundation
import CoreGraphics

struct SpokenAlert {
    let level: AlertLevel
    let message: String
}

protocol AlertPolicyApplying {
    mutating func update(_ decisions: [HazardDecision], at time: TimeInterval) -> SpokenAlert?
    mutating func reset()
}

struct AlertPolicy: AlertPolicyApplying {
    private struct Track {
        var label: String
        var bounds: CGRect
        var first: TimeInterval
        var last: TimeInterval
        var level: AlertLevel
    }
    private var tracks: [Track] = []
    private var lastTime: TimeInterval?
    private var lastSpoken: TimeInterval = -.infinity
    private var lastLevel: AlertLevel = .silence
    private(set) var rationale = "No confirmed hazard"

    mutating func reset() {
        tracks = []
        lastTime = nil
        lastSpoken = -.infinity
        lastLevel = .silence
        rationale = "Reset"
    }

    mutating func update(_ decisions: [HazardDecision], at time: TimeInterval) -> SpokenAlert? {
        guard time.isFinite else { reset(); return nil }
        if let previous = lastTime, time < previous || time - previous > 0.5 { reset() }
        lastTime = time
        let previous = tracks
        tracks = []
        var used: Set<Int> = []
        var eligible: [HazardDecision] = []
        for decision in decisions where decision.level != .silence {
            let object = decision.detection
            let match = previous.indices.filter {
                !used.contains($0) && previous[$0].label == object.label &&
                time - previous[$0].last <= 0.3 &&
                Self.overlap(previous[$0].bounds, object.bounds) >= 0.35
            }.max { Self.overlap(previous[$0].bounds, object.bounds) <
                    Self.overlap(previous[$1].bounds, object.bounds) }
            var track = Track(label: object.label, bounds: object.bounds, first: time,
                              last: time, level: decision.level)
            if let match {
                used.insert(match)
                track.first = previous[match].level == decision.level ? previous[match].first : time
            }
            tracks.append(track)
            let confirmation = decision.level == .urgent ? 0.2 : 0.7
            if time - track.first >= confirmation { eligible.append(decision) }
        }
        guard let best = eligible.max(by: { $0.level < $1.level }) else {
            rationale = tracks.isEmpty ? "Suppressed: no actionable evidence" : "Suppressed: temporal confirmation"
            return nil
        }
        // Global cooldown tolerates identity jitter and disappearance/reappearance.
        // Escalation bypasses cooldown, but still requires urgent confirmation.
        guard time - lastSpoken >= 8 || best.level > lastLevel else {
            rationale = "Suppressed: repeat cooldown"
            return nil
        }
        lastSpoken = time
        lastLevel = best.level
        rationale = "Speak: \(best.message)"
        return SpokenAlert(level: best.level, message: best.message)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / max(a.width * a.height + b.width * b.height - area, 0.000001)
    }
}
