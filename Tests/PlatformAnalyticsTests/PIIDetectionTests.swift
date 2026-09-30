import XCTest

@testable import PlatformAnalytics

final class PIIDetectionTests: XCTestCase {
    func testEmails() {
        XCTAssertTrue(Validator.containsPII("jane.doe+test@example.co.uk"))
        XCTAssertTrue(Validator.containsPII("contact: JANE@EXAMPLE.COM, merci"))
        XCTAssertFalse(Validator.containsPII("@handle"))
        XCTAssertFalse(Validator.containsPII("a@b"))
    }

    func testE164PhoneNumbers() {
        XCTAssertTrue(Validator.containsPII("+33612345678"))
        XCTAssertTrue(Validator.containsPII("+33 6 12 34 56 78"))
        XCTAssertTrue(Validator.containsPII("appelle le +1-415-555-2671"))
        XCTAssertFalse(Validator.containsPII("+12"))
        XCTAssertFalse(Validator.containsPII("+0612345678"))
        XCTAssertFalse(Validator.containsPII("1234567890"))
    }

    func testIPv4() {
        XCTAssertTrue(Validator.containsPII("192.168.1.10"))
        XCTAssertTrue(Validator.containsPII("from 8.8.8.8 today"))
        XCTAssertFalse(Validator.containsPII("256.1.1.1"))
        XCTAssertFalse(Validator.containsPII("2.1.0"))
        XCTAssertFalse(Validator.containsPII("1.2.3.4.5"))
    }

    func testIPv6() {
        XCTAssertTrue(Validator.containsPII("2001:0db8:85a3:0000:0000:8a2e:0370:7334"))
        XCTAssertTrue(Validator.containsPII("2001:db8::1"))
        XCTAssertTrue(Validator.containsPII("addr fe80::1%en0"))
        XCTAssertTrue(Validator.containsPII("::ffff:10.0.0.1"))
        XCTAssertFalse(Validator.containsPII("12:30:45"))
        XCTAssertFalse(Validator.containsPII("::"))
        XCTAssertFalse(Validator.containsPII("a:b"))
    }

    func testOrdinaryValuesAreNotPII() {
        for value in [
            "pro_yearly", "Settings", "Onboarding/Step2", "fr_FR", "iPhone16,1", "2026-09-30", "v2.1.0 (214)",
        ] {
            XCTAssertFalse(Validator.containsPII(value), value)
        }
    }
}
