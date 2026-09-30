import XCTest
import os

@testable import PlatformAnalytics

final class TransportTests: XCTestCase {
    func testResponseTable() {
        let empty = Data()
        XCTAssertEqual(
            URLSessionTransport.result(status: 202, retryAfter: nil, body: Data(#"{"accepted":3,"rejected":1}"#.utf8)),
            .accepted(accepted: 3, rejected: 1))
        XCTAssertEqual(
            URLSessionTransport.result(status: 429, retryAfter: "120", body: empty), .rateLimited(retryAfter: 120))
        XCTAssertEqual(
            URLSessionTransport.result(status: 429, retryAfter: nil, body: empty), .rateLimited(retryAfter: nil))
        XCTAssertEqual(
            URLSessionTransport.result(status: 401, retryAfter: nil, body: empty), .unauthorized(status: 401))
        XCTAssertEqual(
            URLSessionTransport.result(status: 403, retryAfter: nil, body: empty), .unauthorized(status: 403))
        XCTAssertEqual(
            URLSessionTransport.result(
                status: 422, retryAfter: nil, body: Data(#"{"code":"validation_failed","detail":"bad"}"#.utf8)),
            .rejected(status: 422, detail: "bad"))
        for status in [400, 404, 409, 413, 426] {
            XCTAssertEqual(
                URLSessionTransport.result(status: status, retryAfter: nil, body: empty),
                .rejected(status: status, detail: nil))
        }
        for status in [500, 502, 503] {
            XCTAssertEqual(
                URLSessionTransport.result(status: status, retryAfter: nil, body: empty),
                .retryable(reason: "HTTP \(status)"))
        }
    }

    func testRequestShape() async throws {
        let peek = EventQueue.Peek(
            events: [QueuedEvent(name: "e", occurredAt: Date(), sessionID: "S", props: [:])], lineCount: 1, end: 1)
        let batch = try XCTUnwrap(
            Batch(peek: peek, device: .fixture(), sentAt: Date(timeIntervalSince1970: 1_790_000_000)))
        let transport = URLSessionTransport(
            endpoint: try XCTUnwrap(URL(string: "https://api.example.test/v1")), ingestKey: "ik_live_abc",
            protocolClasses: [StubProtocol.self])

        let result = await transport.send(batch)
        XCTAssertEqual(result, .accepted(accepted: 1, rejected: 0))
        let request = try XCTUnwrap(StubProtocol.lastRequest.withLock { $0 })
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/ingest/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ik_live_abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), batch.idempotencyKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
}

/// Intercepte les requêtes de `URLSessionTransport` et répond `202`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lastRequest = OSAllocatedUnfairLock<URLRequest?>(uncheckedState: nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest.withLock { $0 = request }
        let url = request.url ?? URL(filePath: "/")
        let response = HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(#"{"accepted":1,"rejected":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
