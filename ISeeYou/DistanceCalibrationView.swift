import SwiftUI

struct DistanceCalibrationView: View {
    @ObservedObject var calibration: DistanceCalibration
    let detections: [Detection]
    let frameAgeMS: Double
    let frameDate: Date
    @State private var actual = 1.0
    @State private var label = ""
    @State private var validation = false
    @State private var confirmingReset = false
    private var candidates: [Detection] { detections.filter { $0.confidence >= 0.8 && $0.distance != nil } }
    private var selected: Detection? { candidates.filter { $0.label == label }.max { $0.confidence < $1.confidence } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Indoor distance calibration").font(.headline)
            Text("Estimates are unverified. Keep the phone still and select one isolated object. Measure from the rear camera to its visible surface. Reposition between samples. Test varied lighting and object types; a pass here is a limited bench check.").font(.caption)
            Picker("Object to measure", selection: $label) {
                Text("Select an object").tag("")
                ForEach(Array(Set(candidates.map(\.label))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            if let selected, let value = selected.distance {
                TwoLineExplanation(text: String(format: "%@: raw %.2f m · corrected %.2f m (unverified)",
                    selected.label, value.metres, value.metres * (calibration.profile.scale ?? 1)))
            } else { TwoLineExplanation(text: "No selected object with valid depth. Keep only one object of the selected type in view.") }
            Picker("Measured distance", selection: $actual) {
                ForEach(CalibrationProfile.targets, id: \.self) { Text(String(format: "%.1f m", $0)).tag($0) }
            }
            Toggle("Held-out validation sample", isOn: $validation)
            Text("First collect calibration at 0.5, 1 and 2 m. Then switch to validation: three fresh samples at each listed distance. Every validation error must be within 10 cm or 15%, whichever is larger.").font(.caption)
            Button("Record measured sample") {
                guard let selected else { return }
                calibration.record(selected, actual: actual,
                    latencyMS: frameAgeMS + Date().timeIntervalSince(frameDate) * 1000, validation: validation)
            }.disabled(selected == nil || candidates.filter { $0.label == label }.count != 1)
            TwoLineExplanation(text: calibration.status).font(.caption)
            Text(calibration.profile.passed ? "Bench checks passed for this profile. Experimental distance speech can be enabled." : "Numerical speech locked: physical checks incomplete or failed.")
                .font(.caption.bold())
            Text("Samples: \(calibration.profile.trials.count)").font(.caption)
            ForEach(CalibrationProfile.targets, id: \.self) { target in
                let trials = calibration.profile.trials.filter { $0.validation && $0.actual == target }
                Text(String(format: "%.1f m validation: %d/3 · latest error %@", target, min(3, trials.count),
                    trials.last.map { String(format: "%.2f m", $0.error) } ?? "—")).font(.caption.monospacedDigit())
            }
            ShareLink("Export calibration CSV", item: calibration.csv)
            Button("Reset calibration", role: .destructive) { confirmingReset = true }
                .confirmationDialog("Clear calibration and lock numerical speech?", isPresented: $confirmingReset) {
                    Button("Clear calibration", role: .destructive) { calibration.reset() }
                }
        }
    }
}
