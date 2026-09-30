import XCTest

@testable import PlatformAnalytics

final class EventQueueTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "EventQueueTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(_ index: Int) -> QueuedEvent {
        QueuedEvent(
            name: "event_\(index)", occurredAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
            sessionID: "S", props: ["index": .int(index)])
    }

    private var fileURL: URL { directory.appending(path: "queue.jsonl") }

    private func lines() throws -> [String] {
        try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testAppendPeekAckIsFIFO() {
        let queue = EventQueue(directory: directory, maxEvents: 100)
        for index in 0..<5 { queue.append(event(index)) }
        XCTAssertEqual(queue.count, 5)
        let peek = queue.peek(3)
        XCTAssertEqual(peek.events.map(\.name), ["event_0", "event_1", "event_2"])
        XCTAssertEqual(peek.lineCount, 3)
        XCTAssertEqual(queue.count, 5, "peek ne retire rien")
        queue.ack(peek)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.peek(10).events.map(\.name), ["event_3", "event_4"])
    }

    func testOneJSONLinePerEventInBatchFormat() throws {
        let queue = EventQueue(directory: directory, maxEvents: 100)
        var sample = event(1)
        sample.occurredAt = Date(timeIntervalSince1970: 1_790_000_001.125)
        queue.append(sample)
        queue.sync()
        XCTAssertEqual(
            try lines(),
            [#"{"name":"event_1","occurred_at":"2026-09-21T14:13:21.125Z","props":{"index":1},"session_id":"S"}"#])
    }

    func testSurvivesRelaunchIncludingAckedHead() {
        do {
            let queue = EventQueue(directory: directory, maxEvents: 100)
            for index in 0..<6 { queue.append(event(index)) }
            queue.ack(queue.peek(2))
        }
        let reopened = EventQueue(directory: directory, maxEvents: 100)
        XCTAssertEqual(reopened.count, 4)
        XCTAssertEqual(reopened.peek(1).events.first?.name, "event_2")
    }

    func testCompactsWhenMoreThanHalfTheLinesAreDead() throws {
        let queue = EventQueue(directory: directory, maxEvents: 100)
        for index in 0..<10 { queue.append(event(index)) }
        queue.ack(queue.peek(5))
        XCTAssertEqual(try lines().count, 10, "50 % pile : pas encore de compaction")
        queue.ack(queue.peek(1))
        XCTAssertEqual(try lines().count, 4, "compacté : seules les lignes vivantes restent")
        XCTAssertEqual(queue.count, 4)
        XCTAssertEqual(queue.peek(10).events.map(\.name), ["event_6", "event_7", "event_8", "event_9"])
        queue.append(event(10))
        XCTAssertEqual(queue.peek(10).events.last?.name, "event_10")
    }

    func testMaxQueuedEventsDropsOldestFirst() {
        let queue = EventQueue(directory: directory, maxEvents: 3)
        for index in 0..<5 { queue.append(event(index)) }
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.peek(10).events.map(\.name), ["event_2", "event_3", "event_4"])
    }

    func testTruncatedLastLineAndGarbageAreSkipped() throws {
        let queue = EventQueue(directory: directory, maxEvents: 100)
        queue.append(event(0))
        queue.sync()
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"name\":\"trunc".utf8))
        try handle.close()

        let reopened = EventQueue(directory: directory, maxEvents: 100)
        XCTAssertEqual(reopened.count, 2, "la ligne tronquée est retirée, la ligne illisible reste comptée")
        let peek = reopened.peek(10)
        XCTAssertEqual(peek.events.map(\.name), ["event_0"])
        XCTAssertEqual(peek.lineCount, 2)
        reopened.ack(peek)
        XCTAssertEqual(reopened.count, 0)
        reopened.append(event(1))
        XCTAssertEqual(reopened.peek(10).events.map(\.name), ["event_1"])
    }

    func testAckIsSafeWhenTheHeadMovedDuringASend() {
        let queue = EventQueue(directory: directory, maxEvents: 4)
        for index in 0..<4 { queue.append(event(index)) }
        let inFlight = queue.peek(2)  // event_0, event_1
        queue.append(event(4))  // plafond : event_0 droppé
        queue.append(event(5))  // plafond : event_1 droppé (compaction)
        queue.ack(inFlight)
        XCTAssertEqual(queue.peek(10).events.map(\.name), ["event_2", "event_3", "event_4", "event_5"])

        let beforePurge = queue.peek(2)
        queue.purge()
        queue.append(event(6))
        queue.ack(beforePurge)
        XCTAssertEqual(queue.peek(10).events.map(\.name), ["event_6"], "un ack antérieur à la purge est sans effet")
    }

    func testPurgeEmptiesEverything() {
        let queue = EventQueue(directory: directory, maxEvents: 100)
        for index in 0..<3 { queue.append(event(index)) }
        queue.purge()
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.peek(10).events.isEmpty)
        queue.append(event(9))
        XCTAssertEqual(EventQueue(directory: directory, maxEvents: 100).count, 1)
    }

    func testDirectoryIsExcludedFromBackup() throws {
        _ = EventQueue(directory: directory, maxEvents: 10)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testDefaultDirectoryIsApplicationSupport() throws {
        let url = try XCTUnwrap(EventQueue.defaultDirectory())
        XCTAssertEqual(url.lastPathComponent, "com.platform.analytics")
        #if os(macOS)
            // Application Support/<bundle id>/com.platform.analytics : dossier partagé entre apps sur macOS.
            let owner = url.deletingLastPathComponent()
            XCTAssertEqual(owner.lastPathComponent, Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
            XCTAssertEqual(owner.deletingLastPathComponent().lastPathComponent, "Application Support")
        #else
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
        #endif
    }
}
