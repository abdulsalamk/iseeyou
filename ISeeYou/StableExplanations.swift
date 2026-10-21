import SwiftUI

struct TwoLineExplanation: View {
    let text: String
    var body: some View {
        Text(text)
            .lineLimit(2, reservesSpace: true)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DecisionExplanationPanel: View {
    let explanations: [String]
    @ScaledMetric(relativeTo: .caption) private var panelHeight = 140.0
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if explanations.isEmpty {
                    TwoLineExplanation(text: "No object decisions yet")
                }
                // Stable row identities avoid rebuilding the entire panel for
                // every camera frame's newly generated detection UUIDs.
                ForEach(explanations.indices, id: \.self) { index in
                    TwoLineExplanation(text: explanations[index])
                }
            }.font(.caption)
        }
        .frame(height: panelHeight)
        .accessibilityIdentifier("decisionExplanationPanel")
    }
}
