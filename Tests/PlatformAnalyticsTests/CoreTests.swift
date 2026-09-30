import XCTest

@testable import PlatformAnalytics

final class CoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = temporaryDirectory("CoreTests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCore() -> AnalyticsCore { AnalyticsCore.make(directory: directory) }

    func testEventsTrackedBeforeConfigureAreKeptUpToOneHundred() async {
        let core = makeCore()
        for index in 0..<105 {
            await core.handle(.track(name: "early", props: ["i": .int(index)], at: Date()))
        }
        await core.configureForTests()
        let names = await core.queuedEvents().filter { $0.name == "early" }
        XCTAssertEqual(names.count, 100)
        XCTAssertEqual(names.first?.props["i"], 0)
        XCTAssertEqual(names.last?.props["i"], 99)
    }

    func testInvalidEventsAreDroppedAndPropsSanitized() async {
        let core = makeCore()
        await core.configureForTests()
        await core.handle(.track(name: "Bad Name", props: [:], at: Date()))
        await core.handle(.track(name: "$session_start", props: [:], at: Date()))
        await core.handle(.track(name: "signup", props: ["email": "a@b.io", "plan": "pro"], at: Date()))
        let events = await core.queuedEvents().filter { !$0.name.hasPrefix("$session") }
        XCTAssertEqual(events.map(\.name), ["signup"])
        XCTAssertEqual(events.first?.props, ["plan": "pro"])
    }

    func testScreenBecomesDollarScreenWithName() async {
        let core = makeCore()
        await core.configureForTests()
        await core.handle(.screen(name: "Settings", props: ["name": "ignored", "tab": "general"], at: Date()))
        await core.handle(.screen(name: "  ", props: [:], at: Date()))
        let screens = await core.queuedEvents().filter { $0.name == "$screen" }
        XCTAssertEqual(screens.count, 1)
        XCTAssertEqual(screens.first?.props, ["name": "Settings", "tab": "general"])
    }

    func testScreenPropsKeepNameWhenCallerSendsTooMany() throws {
        var props: [String: PropValue] = [:]
        for index in 0..<25 { props["a\(index)"] = .int(index) }
        let result = try XCTUnwrap(AnalyticsCore.screenProps(name: "Home", props: props))
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result["name"], "Home")
        XCTAssertNil(AnalyticsCore.screenProps(name: "jane@example.com", props: [:]))
    }

    func testOptionsAreSanitized() {
        let options = Analytics.Options(flushInterval: -3, flushThreshold: 0, maxQueuedEvents: -1).sanitized
        XCTAssertEqual(options.flushInterval, 1)
        XCTAssertEqual(options.flushThreshold, 1)
        XCTAssertEqual(options.maxQueuedEvents, 1)
        XCTAssertEqual(Analytics.Options().sanitized, Analytics.Options())
    }
}
