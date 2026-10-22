import Foundation
import Combine

struct DistanceTrial: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let modelID: String
    let label: String
    let actual: Double
    let raw: Double
    let scale: Double
    let latencyMS: Double
    let validation: Bool
    var predicted: Double { raw * scale }
    var error: Double { abs(predicted - actual) }
}

struct CalibrationProfile: Codable {
    var trials: [DistanceTrial] = []
    var referenceScale: Double? = nil // User measured single-point correction; never a validation pass.
    static let targets: [Double] = [0.5, 1, 1.5, 2, 3, 5]
    var scale: Double? {
        let training = trials.filter { !$0.validation && $0.modelID == MetricDepthEstimator.modelID }
        guard [0.5, 1.0, 2.0].allSatisfy({ target in training.contains { $0.actual == target } }) else { return referenceScale.flatMap { $0.isFinite && (0.5...2).contains($0) ? $0 : nil } }
        let ratios = training.map { $0.actual / $0.raw }.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !ratios.isEmpty else { return nil }
        let result = ratios[ratios.count/2]
        return (0.5...2).contains(result) ? result : nil
    }
    var passed: Bool {
        guard let scale else { return false }
        let heldOut = trials.filter { $0.validation && $0.modelID == MetricDepthEstimator.modelID && abs($0.scale-scale) < 0.000001 }
        return Self.targets.allSatisfy { target in
            let samples = heldOut.filter { $0.actual == target }.suffix(3)
            return samples.count == 3 && samples.allSatisfy { $0.error <= max(0.1, target * 0.15) }
        }
    }
}

final class DistanceCalibration: ObservableObject {
    @Published private(set) var profile: CalibrationProfile
    @Published private(set) var status = "Measure from the rear camera to the visible object surface."
    private let url: URL
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("distance-calibration.json")
        profile = (try? JSONDecoder().decode(CalibrationProfile.self, from: Data(contentsOf: self.url))) ?? CalibrationProfile()
    }
    func record(_ item: Detection, actual: Double, latencyMS: Double, validation: Bool) {
        guard let distance = item.distance, item.confidence >= 0.8,
              CalibrationProfile.targets.contains(actual), latencyMS <= 500 else {
            status = "Need a fresh, confident, valid distance reading."; return
        }
        guard profile.trials.last.map({ Date().timeIntervalSince($0.date) >= 2 }) ?? true else {
            status = "Wait two seconds and reposition before the next sample."; return
        }
        guard !validation || profile.scale != nil else {
            status = "First record calibration samples at 0.5, 1 and 2 metres."; return
        }
        // Calibration is frozen once held-out validation starts. Start a new
        // profile before collecting more training data; never fit held-out data.
        guard validation || !profile.trials.contains(where: \.validation) else {
            status = "Calibration frozen. Reset before changing calibration samples."; return
        }
        let trial = DistanceTrial(date: Date(), modelID: MetricDepthEstimator.modelID,
            label: item.label, actual: actual, raw: distance.metres,
            scale: validation ? profile.scale! : 1, latencyMS: latencyMS, validation: validation)
        var updated = profile; updated.trials.append(trial)
        save(updated, success: String(format: "Saved %@: %.2f m raw; error %.2f m", item.label, distance.metres, trial.error))
    }
    func applyReference(actual: Double, reported: Double) {
        let factor = actual / reported
        guard actual.isFinite, reported.isFinite, actual > 0, reported > 0,
              factor.isFinite, (0.5...2).contains(factor) else {
            status = "Reference must be positive and correction between 0.5× and 2×."; return
        }
        // Reported is the currently displayed (possibly already corrected) value.
        let rawScale = (profile.scale ?? 1) * factor
        guard (0.5...2).contains(rawScale) else { status = "Correction outside supported range."; return }
        var updated = CalibrationProfile()
        updated.referenceScale = rawScale
        save(updated, success: String(format: "Single-point correction %.3f× saved. Previous bench samples cleared; check other distances.", rawScale))
    }
    func reset() { save(CalibrationProfile(), success: "Calibration cleared; using unverified raw estimates.") }
    private func save(_ updated: CalibrationProfile, success: String) {
        do {
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            profile = updated; status = success
        } catch { status = "Could not save calibration: " + error.localizedDescription }
    }
    var csv: String {
        let heading = "date,model,label,actual_m,raw_m,scale,predicted_m,error_m,latency_ms,validation\n"
        return heading + profile.trials.map { t in
            [ISO8601DateFormatter().string(from: t.date), t.modelID, t.label.replacingOccurrences(of: ",", with: " "),
             String(t.actual), String(t.raw), String(t.scale), String(t.predicted), String(t.error),
             String(t.latencyMS), String(t.validation)].joined(separator: ",")
        }.joined(separator: "\n")
    }
}
