import SwiftUI
import XCTest

@testable import PlatformAnalytics

final class AnalyticsScreenModifierTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testSameNameTwiceInARowWithinOneSecondCountsOnce() {
        var deduplicator = AnalyticsScreenModifier.Deduplicator()
        XCTAssertTrue(deduplicator.shouldEmit("Settings", at: t0))
        XCTAssertFalse(deduplicator.shouldEmit("Settings", at: t0 + 0.4))
        XCTAssertFalse(
            deduplicator.shouldEmit("Settings", at: t0 + 0.99), "fenêtre mesurée depuis la dernière émission")
        XCTAssertTrue(deduplicator.shouldEmit("Settings", at: t0 + 1))
    }

    func testDifferentNamesAreNotDeduplicated() {
        var deduplicator = AnalyticsScreenModifier.Deduplicator()
        XCTAssertTrue(deduplicator.shouldEmit("Home", at: t0))
        XCTAssertTrue(deduplicator.shouldEmit("Settings", at: t0 + 0.1))
        XCTAssertTrue(deduplicator.shouldEmit("Home", at: t0 + 0.2), "pas « deux fois de suite »")
    }

    func testClockGoingBackwardsDoesNotSwallowScreens() {
        var deduplicator = AnalyticsScreenModifier.Deduplicator()
        XCTAssertTrue(deduplicator.shouldEmit("Home", at: t0))
        XCTAssertTrue(deduplicator.shouldEmit("Home", at: t0 - 10))
    }

    @MainActor
    func testModifierIsAvailableOnAnyView() {
        let view = Text("Réglages").analyticsScreen("Settings", props: ["tab": "general"])
        XCTAssertNotNil(view as Any)
    }
}
