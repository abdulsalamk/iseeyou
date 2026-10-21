import XCTest
import SwiftUI
@testable import ISeeYou

@MainActor
final class StableExplanationTests: XCTestCase {
    func testExplanationHeightIsStableForShortAndWrappingText() {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let heights = ["Foot outside", String(repeating: "Foot outside candidate corridor. ", count: 12)].map { text in
                UIHostingController(rootView: TwoLineExplanation(text: text).font(.caption)
                    .environment(\.dynamicTypeSize, size))
                    .sizeThatFits(in: CGSize(width: 240, height: 1000)).height
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 1)
        }
    }
    func testDecisionPanelHeightDoesNotChangeWithObjectCount() {
        let empty = UIHostingController(rootView: DecisionExplanationPanel(explanations: []))
            .sizeThatFits(in: CGSize(width: 240, height: 1000)).height
        let full = UIHostingController(rootView: DecisionExplanationPanel(explanations: Array(repeating: "Foot outside corridor", count: 12)))
            .sizeThatFits(in: CGSize(width: 240, height: 1000)).height
        XCTAssertEqual(empty, full, accuracy: 1)
    }
}
