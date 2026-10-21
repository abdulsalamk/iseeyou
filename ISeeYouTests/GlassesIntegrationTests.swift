import XCTest
@testable import ISeeYou

final class GlassesIntegrationTests: XCTestCase {
    func testOnlyScopedMetaCallbacksAreAccepted() throws {
        XCTAssertTrue(GlassesCallbackPolicy.accepts(try XCTUnwrap(URL(string: "iseeyou://?metaWearablesAction=register"))))
        XCTAssertTrue(GlassesCallbackPolicy.accepts(try XCTUnwrap(URL(string: "https://abdulsalamk.github.io/iseeyou/?metaWearablesAction=register"))))
        for value in ["https://example.com/iseeyou/?metaWearablesAction=register",
                      "https://abdulsalamk.github.io/other/?metaWearablesAction=register",
                      "https://abdulsalamk.github.io/iseeyou/",
                      "other://?metaWearablesAction=register"] {
            XCTAssertFalse(GlassesCallbackPolicy.accepts(try XCTUnwrap(URL(string: value))))
        }
    }
}
