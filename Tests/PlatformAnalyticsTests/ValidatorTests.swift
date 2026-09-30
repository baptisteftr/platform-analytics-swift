import XCTest

@testable import PlatformAnalytics

final class ValidatorTests: XCTestCase {
    func testEventNames() {
        XCTAssertTrue(Validator.isValidName("purchase_completed", allowReserved: false))
        XCTAssertTrue(Validator.isValidName("step_3", allowReserved: false))
        XCTAssertTrue(Validator.isValidName(String(repeating: "a", count: 64), allowReserved: false))
        XCTAssertFalse(Validator.isValidName(String(repeating: "a", count: 65), allowReserved: false))
        XCTAssertFalse(Validator.isValidName("", allowReserved: false))
        XCTAssertFalse(Validator.isValidName("Purchase", allowReserved: false))
        XCTAssertFalse(Validator.isValidName("purchase-completed", allowReserved: false))
        XCTAssertFalse(Validator.isValidName("achat_réussi", allowReserved: false))
        XCTAssertFalse(Validator.isValidName("with space", allowReserved: false))
    }

    func testReservedNamesAreForTheSDKExceptCrash() {
        XCTAssertFalse(Validator.isValidName("$screen", allowReserved: false))
        XCTAssertFalse(Validator.isValidName("$session_start", allowReserved: false))
        XCTAssertTrue(Validator.isValidName("$crash", allowReserved: false))
        XCTAssertTrue(Validator.isValidName("$screen", allowReserved: true))
        XCTAssertFalse(Validator.isValidName("$", allowReserved: true))
        XCTAssertFalse(Validator.isValidName("$$crash", allowReserved: true))
    }

    func testInvalidKeysAreDroppedEventKept() {
        let props: [String: PropValue] = ["ok": 1, "Bad": 2, "also-bad": 3, String(repeating: "k", count: 33): 4]
        XCTAssertEqual(Validator.sanitize(props, event: "e"), ["ok": 1])
    }

    func testStringsAreTruncatedTo256Characters() {
        let long = String(repeating: "é", count: 300)
        let result = Validator.sanitize(["text": .string(long)], event: "e")
        XCTAssertEqual(result["text"], .string(String(repeating: "é", count: 256)))
    }

    func testAtMostTwentyPropsKeepingKeysInAlphabeticalOrder() {
        var props: [String: PropValue] = [:]
        for index in 0..<25 { props[String(format: "k%02d", index)] = .int(index) }
        let result = Validator.sanitize(props, event: "e")
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.keys.sorted().first, "k00")
        XCTAssertEqual(result.keys.sorted().last, "k19")
    }

    func testPropsOverFourKilobytesAreAllDropped() {
        var props: [String: PropValue] = [:]
        for index in 0..<20 { props["key_\(index)"] = .string(String(repeating: "x", count: 250)) }
        XCTAssertGreaterThan(Validator.serializedSize(props), 4_096)
        XCTAssertEqual(Validator.sanitize(props, event: "e"), [:])
    }

    func testNonFiniteDoublesAreDropped() {
        let result = Validator.sanitize(["nan": .double(.nan), "inf": .double(.infinity), "ok": 1.5], event: "e")
        XCTAssertEqual(result, ["ok": 1.5])
    }

    func testPIIValuesAreDroppedOtherPropsKept() {
        let result = Validator.sanitize(["contact": "jane@example.com", "plan": "pro"], event: "e")
        XCTAssertEqual(result, ["plan": "pro"])
    }

    func testPropValueLiteralsAndJSON() throws {
        let props: [String: PropValue] = ["s": "a", "i": 3, "d": 29.99, "b": false]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(props), as: UTF8.self)
        XCTAssertEqual(json, #"{"b":false,"d":29.99,"i":3,"s":"a"}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: PropValue].self, from: Data(json.utf8)), props)
    }
}
