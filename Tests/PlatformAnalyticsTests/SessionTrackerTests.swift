import XCTest

@testable import PlatformAnalytics

final class SessionTrackerTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() { directory = temporaryDirectory("SessionTrackerTests") }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private var markerURL: URL { directory.appending(path: "session.active") }

    private func sessionEvents(_ core: AnalyticsCore) async -> [QueuedEvent] {
        await core.queuedEvents().filter { $0.name.hasPrefix("$") }
    }

    func testFirstSessionOnFreshDeviceThenNotFirst() async {
        let store = MemoryStore()
        let core = AnalyticsCore.make(directory: directory, store: store)
        await core.configureForTests(at: t0)
        let first = await sessionEvents(core)
        XCTAssertEqual(first.map(\.name), ["$session_start"])
        XCTAssertEqual(first.first?.props, ["first": true])
        XCTAssertEqual(first.first?.occurredAt, t0)
        let deviceID = await core.device?.id
        XCTAssertEqual(deviceID, store.stored)

        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 1))
        let relaunched = AnalyticsCore.make(directory: temporaryDirectory("relaunch"), store: store)
        await relaunched.configureForTests(at: t0 + 100)
        let second = await sessionEvents(relaunched)
        XCTAssertEqual(second.first?.props, ["first": false])
        let relaunchedID = await relaunched.device?.id
        XCTAssertEqual(relaunchedID, deviceID, "le device_id survit au relancement")
    }

    func testShortBackgroundResumesLongBackgroundStartsNewSession() async {
        let core = AnalyticsCore.make(directory: directory)
        await core.configureForTests(at: t0)
        await core.handle(.lifecycle(.didBecomeActive, at: t0 + 0.2))  // déjà active : ignoré
        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 10))
        await core.handle(.lifecycle(.didBecomeActive, at: t0 + 40))  // 30 s pile : reprise
        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 45))
        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 46))  // doublon : ignoré
        await core.handle(.lifecycle(.didBecomeActive, at: t0 + 75.5))  // 30,5 s : nouvelle session

        let events = await sessionEvents(core)
        XCTAssertEqual(
            events.map(\.name), ["$session_start", "$session_end", "$session_end", "$session_start"])
        XCTAssertEqual(events[1].props, ["duration_ms": 10_000])
        XCTAssertEqual(events[2].props, ["duration_ms": 15_000], "durée cumulée au premier plan")
        XCTAssertEqual(events[3].props, ["first": false])
        XCTAssertEqual(events[0].sessionID, events[2].sessionID)
        XCTAssertNotEqual(events[0].sessionID, events[3].sessionID)
    }

    func testMarkerLivesWhileActiveOnly() async {
        let core = AnalyticsCore.make(directory: directory)
        await core.configureForTests(at: t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        await core.handle(.lifecycle(.didBecomeActive, at: t0 + 6))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "reprise : marqueur réécrit")
    }

    func testLeftoverMarkerEmitsCrashWithPreviousSession() async throws {
        let crashed = AnalyticsCore.make(directory: directory)
        await crashed.configureForTests(at: t0)
        let crashedEvents = await crashed.queuedEvents()
        let crashedSession = try XCTUnwrap(crashedEvents.first?.sessionID)

        let next = AnalyticsCore.make(directory: directory)
        await next.configureForTests(at: t0 + 60)
        let events = await next.queuedEvents().filter { $0.occurredAt == t0 + 60 }
        XCTAssertEqual(events.map(\.name), ["$crash", "$session_start"])
        XCTAssertEqual(events[0].props, ["signal": "unknown", "top_frame": ""])
        XCTAssertEqual(events[0].sessionID, crashedSession)
        XCTAssertNotEqual(events[1].sessionID, crashedSession)
    }

    func testNoCrashAfterCleanBackgroundOrVersionChange() async {
        let clean = AnalyticsCore.make(directory: directory)
        await clean.configureForTests(at: t0)
        await clean.handle(.lifecycle(.didEnterBackground, at: t0 + 1))
        let afterClean = AnalyticsCore.make(directory: directory)
        await afterClean.configureForTests(at: t0 + 60)

        let updated = AnalyticsCore.make(directory: directory, device: .fixture(appVersion: "2.2.0"))
        await updated.configureForTests(at: t0 + 120)
        let osUpdated = AnalyticsCore.make(
            directory: directory, device: .fixture(appVersion: "2.2.0", osVersion: "26.1"))
        await osUpdated.configureForTests(at: t0 + 180)

        let crashes = await osUpdated.queuedEvents().filter { $0.name == "$crash" }
        XCTAssertTrue(crashes.isEmpty)
    }

    func testResetDeviceIDPurgesQueueAndStartsFirstSession() async throws {
        let store = MemoryStore()
        let identity = DeviceIdentity(store: store)
        let core = AnalyticsCore(
            environment: .init(
                queueDirectory: { [directory] in directory }, now: { Date() }, identity: identity,
                device: { .fixture() }))
        await core.configureForTests(at: t0)
        await core.handle(.track(name: "before_reset", props: [:], at: t0 + 1))
        let oldID = identity.current

        let rotated = identity.rotate()
        XCTAssertEqual(identity.current, rotated, "visible immédiatement côté façade")
        XCTAssertNotEqual(store.stored, rotated, "pas encore écrit : aucune I/O dans l'appel public")
        await core.handle(.resetDeviceID(at: t0 + 2))

        XCTAssertEqual(store.stored, rotated)
        let deviceID = await core.device?.id
        XCTAssertEqual(deviceID, rotated)
        XCTAssertNotEqual(oldID, rotated)
        let events = await core.queuedEvents()
        XCTAssertEqual(events.map(\.name), ["$session_start"])
        XCTAssertEqual(events.first?.props, ["first": true])
    }

    func testResetInBackgroundMakesNextSessionFirst() async {
        let identity = DeviceIdentity(store: MemoryStore())
        let core = AnalyticsCore(
            environment: .init(
                queueDirectory: { [directory] in directory }, now: { Date() }, identity: identity,
                device: { .fixture() }))
        await core.configureForTests(at: t0)
        await core.handle(.lifecycle(.didEnterBackground, at: t0 + 1))
        identity.rotate()
        await core.handle(.resetDeviceID(at: t0 + 2))
        await core.handle(.lifecycle(.didBecomeActive, at: t0 + 3))
        let events = await core.queuedEvents()
        XCTAssertEqual(events.map(\.name), ["$session_start"])
        XCTAssertEqual(events.first?.props, ["first": true])
    }
}
