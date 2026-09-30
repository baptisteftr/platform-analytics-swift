import XCTest

@testable import PlatformAnalytics

/// Cas de référence de la détection PII (C02 §3.1), partagés avec le backend : la même table figure dans
/// docs/history/events.md et doit donner le même résultat côté Go.
final class PIIReferenceTests: XCTestCase {
    static let cases: [(rule: String, input: String, pii: Bool)] = [
        ("email", "jane@example.com", true),
        ("email", "contact: JANE.DOE+tag@sub.example.co.uk merci", true),
        ("email", "a@b.co", true),
        ("email", "prénom.nom@exemple.fr", true),
        ("email", "user_1@mail-server.io", true),
        ("email", "a@b.c", false),
        ("email", "a@b", false),
        ("email", "jane@example", false),
        ("email", "@example.com", false),
        ("email", "jane@@example.com", false),
        ("email", "version 1.2@3.4", false),
        ("e164", "+33612345678", true),
        ("e164", "+33 6 12 34 56 78", true),
        ("e164", "+1-415-555-2671", true),
        ("e164", "+1.415.555.2671", true),
        ("e164", "tel:+33612345678;ext", true),
        ("e164", "+1234567", true),
        ("e164", "+123456789012345", true),
        ("e164", "+1234567a", true),
        ("e164", "+123456", false),
        ("e164", "+1234567890123456", false),
        ("e164", "+0612345678", false),
        ("e164", "0612345678", false),
        ("e164", "+33  612345678", false),
        ("e164", "+33 (0)6 12 34 56 78", false),
        ("ipv4", "192.168.1.10", true),
        ("ipv4", "from 8.8.8.8 today", true),
        ("ipv4", "0.0.0.0", true),
        ("ipv4", "255.255.255.255", true),
        ("ipv4", "10.0.0.1:8080", true),
        ("ipv4", "1.2.3.4.", true),
        ("ipv4", "v1.2.3.4", true),
        ("ipv4", "1.2.3.4a", true),
        ("ipv4", "256.1.1.1", false),
        ("ipv4", "1.2.3", false),
        ("ipv4", "2.1.0", false),
        ("ipv4", "1.2.3.4.5", false),
        ("ipv4", "01.2.3.4", false),
        ("ipv4", "192.168.01.1", false),
        ("ipv4", "1.2.3.04", false),
        ("ipv6", "2001:0db8:85a3:0000:0000:8a2e:0370:7334", true),
        ("ipv6", "2001:db8::1", true),
        ("ipv6", "::1", true),
        ("ipv6", "::", true),
        ("ipv6", "addr fe80::1%en0", true),
        ("ipv6", "[2001:db8::1]:443", true),
        ("ipv6", "12:34:56:78:9a:bc:de:f0", true),
        ("ipv6", "::ffff:10.0.0.1", true),
        ("ipv6", "2001:db8::1.", false),
        ("ipv6", "12:30:45", false),
        ("ipv6", "a:b", false),
        ("ipv6", "2001:db8:::1", false),
        ("ipv6", "1:2:3:4:5:6:7:8:9", false),
        ("ipv6", "12345::1", false),
        ("ipv6", "ab:cd:ef:01:23:45", false),
        ("aucune", "pro_yearly", false),
        ("aucune", "Onboarding/Step2", false),
        ("aucune", "iPhone16,1", false),
        ("aucune", "2026-09-30T14:03:00Z", false),
        ("aucune", "v2.1.0 (214)", false),
        ("aucune", "Écran d'accueil", false),
    ]

    func testReferenceTable() {
        for (rule, input, pii) in Self.cases {
            XCTAssertEqual(Validator.containsPII(input), pii, "\(rule) : \(input)")
        }
    }
}
