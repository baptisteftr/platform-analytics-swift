import XCTest

@testable import PlatformAnalytics

final class CoreFlushTests: XCTestCase {
    private var directory: URL!
    private let clock = TestClock()

    override func setUp() { directory = temporaryDirectory("CoreFlushTests") }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func makeCore(
        _ transport: MockTransport, threshold: Int = 10_000, store: MemoryStore = MemoryStore()
    ) async -> AnalyticsCore {
        let core = AnalyticsCore.make(directory: directory, store: store, transport: transport, clock: clock)
        await core.configureForTests(at: clock.now, options: .init(flushThreshold: threshold))
        return core
    }

    private func track(_ core: AnalyticsCore, _ count: Int, props: [String: PropValue] = [:]) async {
        for index in 0..<count {
            await core.handle(.track(name: "event_\(index)", props: props, at: clock.now))
        }
    }

    private func flush(_ core: AnalyticsCore) async {
        await core.handle(.flush(completion: nil))
        await core.waitForFlush()
    }

    func testThresholdTriggersAFlushInBatchFormat() async throws {
        let transport = MockTransport()
        let store = MemoryStore()
        let core = await makeCore(transport, threshold: 3, store: store)
        await track(core, 2)
        await core.waitForFlush()

        let payloads = await transport.payloads
        XCTAssertEqual(payloads.count, 1)
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload.sdk, Batch.SDK(name: "swift", version: "1.0.0"))
        XCTAssertEqual(payload.sentAt, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(payload.device.id, store.stored)
        XCTAssertEqual(payload.device.model, "iPhone16,1")
        XCTAssertEqual(payload.events.map(\.name), ["$session_start", "event_0", "event_1"])
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)

        let jsonValue = await transport.batches.first
        let json = try XCTUnwrap(jsonValue).body
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sdk", "sent_at", "device", "events"])
        let device = try XCTUnwrap(object["device"] as? [String: Any])
        XCTAssertEqual(
            Set(device.keys), ["id", "model", "os_version", "app_version", "build_number", "locale"])
    }

    func testFlushSendsSequentialBatchesOfAtMost500OldestFirst() async {
        let transport = MockTransport()
        let core = await makeCore(transport)
        await track(core, 1_200)
        await flush(core)
        let batches = await transport.batches
        XCTAssertEqual(batches.map(\.eventCount), [500, 500, 201])
        let first = await transport.payloads.first?.events.first?.name
        XCTAssertEqual(first, "$session_start")
        XCTAssertEqual(Set(batches.map(\.idempotencyKey)).count, 3)
    }

    func testBodiesStayUnderOneMegabyte() async {
        let transport = MockTransport()
        let core = await makeCore(transport)
        var props: [String: PropValue] = [:]
        for index in 0..<15 { props["k\(index)"] = .string(String(repeating: "x", count: 250)) }
        await track(core, 400, props: props)
        await flush(core)
        let batches = await transport.batches
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.body.count <= Batch.maxBodyBytes })
        XCTAssertEqual(batches.map(\.eventCount).reduce(0, +), 401)
    }

    func testRetryKeepsKeyAndEventsAndRefreshesSentAt() async throws {
        let transport = MockTransport([.retryable(reason: "HTTP 503")])
        let core = await makeCore(transport)
        await track(core, 2)
        await flush(core)
        var batches = await transport.batches
        XCTAssertEqual(batches.count, 1)
        let backoffUntilValue = await core.backoffUntil
        let backoffUntil = try XCTUnwrap(backoffUntilValue)
        XCTAssertGreaterThanOrEqual(backoffUntil.timeIntervalSince(clock.now), 2.5)
        XCTAssertLessThanOrEqual(backoffUntil.timeIntervalSince(clock.now), 5)

        await track(core, 1)
        await flush(core)
        batches = await transport.batches
        XCTAssertEqual(batches.count, 1, "pas d'envoi pendant le backoff")

        clock.advance(6)
        await flush(core)
        batches = await transport.batches
        XCTAssertEqual(batches.count, 3, "retry du même batch, puis le nouvel événement")
        XCTAssertEqual(batches[1].idempotencyKey, batches[0].idempotencyKey)
        let payloads = await transport.payloads
        XCTAssertEqual(payloads[1].events, payloads[0].events, "mêmes événements d'une tentative à l'autre")
        XCTAssertEqual(payloads[1].device, payloads[0].device)
        XCTAssertEqual(payloads[0].sentAt, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(payloads[1].sentAt, "2026-09-21T14:13:26.000Z", "sent_at rafraîchi à chaque tentative")
        XCTAssertNotEqual(batches[2].idempotencyKey, batches[0].idempotencyKey)
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testNetworkRestoreResetsTheBackoff() async {
        let transport = MockTransport([.retryable(reason: "offline")])
        let core = await makeCore(transport)
        await track(core, 1)
        await flush(core)
        await core.handle(.networkRestored)
        await core.waitForFlush()
        let count = await transport.batches.count
        XCTAssertEqual(count, 2)
        let backoffUntil = await core.backoffUntil
        XCTAssertNil(backoffUntil)
    }

    func testRateLimitHonoursRetryAfterEvenAfterNetworkRestore() async throws {
        let transport = MockTransport([.rateLimited(retryAfter: 120), .rateLimited(retryAfter: nil)])
        let core = await makeCore(transport)
        await track(core, 1)
        await flush(core)
        let untilValue = await core.rateLimitedUntil
        let until = try XCTUnwrap(untilValue)
        XCTAssertEqual(until.timeIntervalSince(clock.now), 120, accuracy: 0.001)
        await core.handle(.networkRestored)
        await flush(core)
        var count = await transport.batches.count
        XCTAssertEqual(count, 1)

        clock.advance(121)
        await flush(core)
        let defaultUntilValue = await core.rateLimitedUntil
        let defaultUntil = try XCTUnwrap(defaultUntilValue)
        XCTAssertEqual(defaultUntil.timeIntervalSince(clock.now), 60, accuracy: 0.001, "Retry-After absent : 60 s")
        clock.advance(61)
        await flush(core)
        count = await transport.batches.count
        XCTAssertEqual(count, 3)
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testUnauthorizedPurgesAndDisablesUntilNextLaunch() async {
        let transport = MockTransport([.unauthorized(status: 401)])
        let core = await makeCore(transport)
        await track(core, 3)
        await flush(core)
        let disabled = await core.disabled
        XCTAssertTrue(disabled)
        await track(core, 3)
        await core.handle(.lifecycle(.didEnterBackground, at: clock.now))
        await flush(core)
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        let count = await transport.batches.count
        XCTAssertEqual(count, 1, "jamais de nouvel essai avec une clé morte")

        let relaunched = AnalyticsCore.make(directory: directory, transport: transport, clock: clock)
        await relaunched.configureForTests(at: clock.now)
        let enabled = await relaunched.disabled
        XCTAssertFalse(enabled, "réactivé au lancement suivant")
    }

    func testInvalidBatchIsDroppedAndTheNextOneStillSent() async {
        let transport = MockTransport([.rejected(status: 422, detail: "events[3].name: invalid")])
        let core = await makeCore(transport)
        await track(core, 599)
        await flush(core)
        let batches = await transport.batches
        XCTAssertEqual(batches.map(\.eventCount), [500, 100])
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
    }

    func testBackgroundEmitsSessionEndThenFlushes() async {
        let transport = MockTransport()
        let core = await makeCore(transport)
        await track(core, 1)
        clock.advance(10)
        await core.handle(.lifecycle(.didEnterBackground, at: clock.now))
        await core.waitForFlush()
        let names = await transport.payloads.flatMap(\.events).map(\.name)
        XCTAssertEqual(names, ["$session_start", "event_0", "$session_end"])
    }

    func testFlushCompletionIsAlwaysCalled() async {
        let core = await makeCore(.offline)
        await withCheckedContinuation { continuation in
            Task { await core.handle(.flush(completion: { continuation.resume() })) }
        }
        let unconfigured = AnalyticsCore.make(directory: temporaryDirectory("unconfigured"))
        await withCheckedContinuation { continuation in
            Task { await unconfigured.handle(.flush(completion: { continuation.resume() })) }
        }
    }

    func testOptOutPurgesStopsEverythingThenResumesWithANewSession() async {
        let transport = MockTransport()
        let core = await makeCore(transport)
        await track(core, 2)
        await core.handle(.setOptOut(true, at: clock.now))
        var queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        await track(core, 2)
        await core.handle(.screen(name: "Settings", props: [:], at: clock.now))
        await core.handle(.lifecycle(.didEnterBackground, at: clock.now))
        await core.handle(.lifecycle(.didBecomeActive, at: clock.now + 100))
        await flush(core)
        queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        var count = await transport.batches.count
        XCTAssertEqual(count, 0, "aucun réseau en opt-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "session.active").path))

        await core.handle(.setOptOut(false, at: clock.now))
        await track(core, 1)
        await flush(core)
        count = await transport.batches.count
        XCTAssertEqual(count, 1)
        let names = await transport.payloads.flatMap(\.events).map(\.name)
        XCTAssertEqual(names, ["$session_start", "event_0"])
    }

    func testConfigureWhileOptedOutCreatesNoSession() async {
        let crashed = AnalyticsCore.make(directory: directory)
        await crashed.configureForTests(at: clock.now)  // marqueur laissé : « crash »
        let transport = MockTransport()
        let core = AnalyticsCore.make(directory: directory, transport: transport, clock: clock)
        await core.handle(.track(name: "early", props: [:], at: clock.now))
        await core.configureForTests(at: clock.now, optedOut: true)
        await flush(core)
        let queued = await core.queuedCount
        XCTAssertEqual(queued, 0)
        let count = await transport.batches.count
        XCTAssertEqual(count, 0)
    }
}

final class BackoffTests: XCTestCase {
    func testExponentialWithJitterCappedAtTenMinutes() {
        var backoff = Backoff()
        var generator = SystemRandomNumberGenerator()
        let ceilings: [TimeInterval] = [5, 10, 20, 40, 80, 160, 320, 600, 600, 600]
        for ceiling in ceilings {
            let delay = backoff.nextDelay(using: &generator)
            XCTAssertGreaterThanOrEqual(delay, ceiling / 2)
            XCTAssertLessThanOrEqual(delay, ceiling)
        }
        backoff.reset()
        XCTAssertLessThanOrEqual(backoff.nextDelay(), 5)
    }
}
