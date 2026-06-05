import XCTest
@testable import VLMKit

/// Logic-only tests for `BusinessCard` — the deterministic shaping between the
/// raw model output and the typed `BusinessCardData`, plus vCard escaping. No
/// model or GPU involved.
final class BusinessCardTests: XCTestCase {

    // MARK: - clean()

    func testCleanTrimsAndDropsBlankStrings() {
        let raw = BusinessCard.BusinessCardRaw(
            givenName: "  Taro  ",
            familyName: "Yamada\n",
            fullName: nil,
            phoneticName: "  ",
            company: "  ACME  ",
            department: nil,
            title: "Engineer",
            phones: nil, emails: nil, urls: nil,
            address: nil, socials: nil
        )
        let cleaned = BusinessCard.clean(raw)
        XCTAssertEqual(cleaned.givenName, "Taro")
        XCTAssertEqual(cleaned.familyName, "Yamada")
        XCTAssertNil(cleaned.phoneticName)   // whitespace-only → nil
        XCTAssertEqual(cleaned.company, "ACME")
        XCTAssertEqual(cleaned.title, "Engineer")
    }

    func testCleanDropsBlankPhonesEmailsUrlsSocials() {
        let raw = BusinessCard.BusinessCardRaw(
            givenName: nil, familyName: nil, fullName: "Jane Doe", phoneticName: nil,
            company: nil, department: nil, title: nil,
            phones: [
                .init(kind: "Mobile", number: "  +1-555-1234  "),
                .init(kind: "Office", number: nil),
                .init(kind: nil, number: "   "),
                .init(kind: "Fax", number: "+1-555-9999"),
            ],
            emails: [" jane@acme.com ", "", "  "],
            urls: ["https://acme.com", "  "],
            address: nil,
            socials: [
                .init(platform: "LinkedIn", handle: "jane-doe"),
                .init(platform: "", handle: "x"),
                .init(platform: "X", handle: nil),
            ]
        )
        let cleaned = BusinessCard.clean(raw)
        XCTAssertEqual(cleaned.phones.map(\.number), ["+1-555-1234", "+1-555-9999"])
        XCTAssertEqual(cleaned.emails, ["jane@acme.com"])
        XCTAssertEqual(cleaned.urls, ["https://acme.com"])
        XCTAssertEqual(cleaned.socials.map(\.platform), ["LinkedIn"])
    }

    // MARK: - normalizePhoneKind()

    func testNormalizePhoneKindSnapsKnownLabelsCaseInsensitively() {
        XCTAssertEqual(BusinessCard.normalizePhoneKind("mobile"), "Mobile")
        XCTAssertEqual(BusinessCard.normalizePhoneKind("OFFICE"), "Office")
        XCTAssertEqual(BusinessCard.normalizePhoneKind("  Fax  "), "Fax")
    }

    func testNormalizePhoneKindMapsCommonSynonyms() {
        XCTAssertEqual(BusinessCard.normalizePhoneKind("Cell"), "Mobile")
        XCTAssertEqual(BusinessCard.normalizePhoneKind("携帯"), "Mobile")
        XCTAssertEqual(BusinessCard.normalizePhoneKind("Work"), "Office")
        XCTAssertEqual(BusinessCard.normalizePhoneKind("代表"), "Office")
    }

    /// Anything we don't recognize survives as printed — better than losing
    /// non-English labels (e.g. "Atelier") to a default bucket.
    func testNormalizePhoneKindPreservesUnknownLabel() {
        XCTAssertEqual(BusinessCard.normalizePhoneKind("Atelier"), "Atelier")
    }

    func testNormalizePhoneKindBlankIsNil() {
        XCTAssertNil(BusinessCard.normalizePhoneKind(nil))
        XCTAssertNil(BusinessCard.normalizePhoneKind(""))
        XCTAssertNil(BusinessCard.normalizePhoneKind("   "))
    }

    // MARK: - displayName

    func testDisplayNameSplitPreferred() {
        let data = sampleData(given: "Taro", family: "Yamada", full: "山田太郎")
        XCTAssertEqual(data.displayName, "Taro Yamada")
    }

    func testDisplayNameFallsBackToFullWhenSplitMissing() {
        let data = sampleData(given: nil, family: nil, full: "Jane Doe")
        XCTAssertEqual(data.displayName, "Jane Doe")
    }

    func testDisplayNameEmptyWhenEverythingMissing() {
        let data = sampleData(given: nil, family: nil, full: nil)
        XCTAssertEqual(data.displayName, "")
    }

    // MARK: - vCard

    func testVCardBasicShape() {
        let data = BusinessCardData(
            givenName: "Taro",
            familyName: "Yamada",
            fullName: nil,
            phoneticName: nil,
            company: "ACME",
            department: "Engineering",
            title: "Lead Engineer",
            phones: [
                .init(kind: "Mobile", number: "+81-90-1234-5678"),
                .init(kind: "Office", number: "+81-3-1234-5678"),
            ],
            emails: ["taro@acme.example"],
            urls: ["https://acme.example"],
            address: "1-2-3 Marunouchi, Chiyoda-ku, Tokyo",
            socials: [
                .init(platform: "LinkedIn", handle: "taro-yamada"),
            ]
        )
        let vcard = BusinessCard.vCard(data)
        XCTAssertTrue(vcard.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0"))
        XCTAssertTrue(vcard.hasSuffix("END:VCARD"))
        XCTAssertTrue(vcard.contains("N:Yamada;Taro;;;"))
        XCTAssertTrue(vcard.contains("FN:Taro Yamada"))
        XCTAssertTrue(vcard.contains("ORG:ACME;Engineering"))
        XCTAssertTrue(vcard.contains("TITLE:Lead Engineer"))
        XCTAssertTrue(vcard.contains("TEL;TYPE=CELL,VOICE:+81-90-1234-5678"))
        XCTAssertTrue(vcard.contains("TEL;TYPE=WORK,VOICE:+81-3-1234-5678"))
        XCTAssertTrue(vcard.contains("EMAIL;TYPE=WORK:taro@acme.example"))
        XCTAssertTrue(vcard.contains("URL:https://acme.example"))
        XCTAssertTrue(vcard.contains("X-SOCIALPROFILE;TYPE=LinkedIn:taro-yamada"))
    }

    /// Commas and semicolons inside the printed address must be vCard-escaped
    /// so they don't get parsed as ADR component separators.
    func testVCardEscapesSpecialCharacters() {
        let data = BusinessCardData(
            givenName: nil, familyName: nil,
            fullName: "Comma, Smith; Jr.",
            phoneticName: nil,
            company: nil, department: nil, title: nil,
            phones: [], emails: [], urls: [],
            address: "Line1, Line2; Floor 5",
            socials: []
        )
        let vcard = BusinessCard.vCard(data)
        XCTAssertTrue(vcard.contains(#"FN:Comma\, Smith\; Jr."#))
        XCTAssertTrue(vcard.contains(#"LABEL:Line1\, Line2\; Floor 5"#))
    }

    func testVCardOmitsFieldsWhenAbsent() {
        let data = BusinessCardData(
            givenName: nil, familyName: nil, fullName: "Solo",
            phoneticName: nil, company: nil, department: nil, title: nil,
            phones: [], emails: [], urls: [], address: nil, socials: []
        )
        let vcard = BusinessCard.vCard(data)
        XCTAssertTrue(vcard.contains("FN:Solo"))
        XCTAssertFalse(vcard.contains("ORG:"))
        XCTAssertFalse(vcard.contains("TEL"))
        XCTAssertFalse(vcard.contains("EMAIL"))
        XCTAssertFalse(vcard.contains("URL:"))
        XCTAssertFalse(vcard.contains("ADR:"))
    }

    // MARK: - Helpers

    private func sampleData(given: String?, family: String?, full: String?) -> BusinessCardData {
        BusinessCardData(
            givenName: given, familyName: family, fullName: full,
            phoneticName: nil, company: nil, department: nil, title: nil,
            phones: [], emails: [], urls: [], address: nil, socials: []
        )
    }
}
