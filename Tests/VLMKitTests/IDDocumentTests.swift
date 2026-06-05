import XCTest
@testable import VLMKit

/// Logic-only tests for `IDDocument` — deterministic shaping between the raw
/// model output and the typed `IDDocumentData`, plus the JSON export shape.
/// No model or GPU involved.
final class IDDocumentTests: XCTestCase {

    // MARK: - clean()

    func testCleanTrimsAndDropsBlanks() {
        let raw = IDDocument.IDRaw(
            documentType: "  Passport  ",
            documentNumber: "  ",
            givenName: "Taro",
            familyName: "Yamada\n",
            fullName: nil,
            dateOfBirth: "1990-01-15",
            sex: nil,
            nationality: "JPN",
            issuingAuthority: nil,
            issueDate: nil,
            expiryDate: nil,
            address: "  ",
            mrz: nil,
            additionalFields: nil
        )
        let cleaned = IDDocument.clean(raw)
        XCTAssertEqual(cleaned.documentType, "Passport")
        XCTAssertNil(cleaned.documentNumber)   // whitespace-only → nil
        XCTAssertEqual(cleaned.givenName, "Taro")
        XCTAssertEqual(cleaned.familyName, "Yamada")
        XCTAssertEqual(cleaned.nationality, "JPN")
        XCTAssertNil(cleaned.address)
        XCTAssertTrue(cleaned.additionalFields.isEmpty)
    }

    func testCleanDropsAdditionalFieldsWithoutLabelOrValue() {
        let raw = IDDocument.IDRaw(
            documentType: nil, documentNumber: nil,
            givenName: nil, familyName: nil, fullName: "Jane Doe",
            dateOfBirth: nil, sex: nil, nationality: nil,
            issuingAuthority: nil, issueDate: nil, expiryDate: nil,
            address: nil, mrz: nil,
            additionalFields: [
                .init(label: "Class", value: "C"),
                .init(label: "", value: "M"),
                .init(label: "Restrictions", value: ""),
                .init(label: "Blood Type", value: "O+"),
            ]
        )
        let cleaned = IDDocument.clean(raw)
        XCTAssertEqual(cleaned.additionalFields.map(\.label), ["Class", "Blood Type"])
    }

    // MARK: - normalizeDocumentType()

    func testNormalizeDocumentTypeSnapsKnown() {
        XCTAssertEqual(IDDocument.normalizeDocumentType("Passport"), "Passport")
        XCTAssertEqual(IDDocument.normalizeDocumentType("passport"), "Passport")
        XCTAssertEqual(IDDocument.normalizeDocumentType("  STUDENT ID  "), "Student ID")
    }

    func testNormalizeDocumentTypeMapsSynonyms() {
        XCTAssertEqual(IDDocument.normalizeDocumentType("Drivers License"), "Driver's License")
        XCTAssertEqual(IDDocument.normalizeDocumentType("運転免許証"), "Driver's License")
        XCTAssertEqual(IDDocument.normalizeDocumentType("マイナンバーカード"), "National ID")
        XCTAssertEqual(IDDocument.normalizeDocumentType("旅券"), "Passport")
    }

    func testNormalizeDocumentTypePreservesUnknown() {
        // Novel ID types survive as printed rather than being dropped — better
        // than a default-bucket lie.
        XCTAssertEqual(IDDocument.normalizeDocumentType("Health Insurance Card"), "Health Insurance Card")
    }

    func testNormalizeDocumentTypeBlankIsNil() {
        XCTAssertNil(IDDocument.normalizeDocumentType(nil))
        XCTAssertNil(IDDocument.normalizeDocumentType("   "))
    }

    // MARK: - displayName

    func testDisplayNamePrefersSplit() {
        let data = sample(given: "Jane", family: "Doe", full: "Jane Catherine Doe")
        XCTAssertEqual(data.displayName, "Jane Doe")
    }

    func testDisplayNameFallsBackToFull() {
        let data = sample(given: nil, family: nil, full: "Jane Doe")
        XCTAssertEqual(data.displayName, "Jane Doe")
    }

    // MARK: - JSON

    func testJSONIncludesAllKeysEvenWhenNull() throws {
        let data = IDDocumentData(
            documentType: "Passport",
            documentNumber: "X1234567",
            givenName: nil, familyName: nil,
            fullName: "Jane Doe",
            dateOfBirth: "1990-01-15",
            sex: "F",
            nationality: "USA",
            issuingAuthority: nil,
            issueDate: nil,
            expiryDate: "2030-01-14",
            address: nil,
            mrz: nil,
            additionalFields: []
        )
        let json = try IDDocument.json(data)
        // Every schema key must appear, even when the value is null — so any
        // downstream Shortcut can key into the object without an exists-check.
        for key in [
            "documentType", "documentNumber", "givenName", "familyName", "fullName",
            "dateOfBirth", "sex", "nationality", "issuingAuthority", "issueDate",
            "expiryDate", "address", "mrz", "additionalFields",
        ] {
            XCTAssertTrue(json.contains("\"\(key)\""), "JSON missing key \(key)")
        }
        XCTAssertTrue(json.contains("\"documentType\" : \"Passport\""))
        XCTAssertTrue(json.contains("\"givenName\" : null"))
    }

    func testJSONRoundTripsAdditionalFields() throws {
        let data = IDDocumentData(
            documentType: "Driver's License",
            documentNumber: "DL-001",
            givenName: nil, familyName: nil, fullName: "John Q. Public",
            dateOfBirth: nil, sex: nil, nationality: nil,
            issuingAuthority: nil, issueDate: nil, expiryDate: nil,
            address: nil, mrz: nil,
            additionalFields: [
                IDField(label: "Class", value: "C"),
                IDField(label: "Restrictions", value: "Corrective lenses"),
            ]
        )
        let json = try IDDocument.json(data)
        let parsed = try JSONDecoder().decode(Decoded.self, from: Data(json.utf8))
        XCTAssertEqual(parsed.additionalFields.count, 2)
        XCTAssertEqual(parsed.additionalFields[0].label, "Class")
        XCTAssertEqual(parsed.additionalFields[1].value, "Corrective lenses")
    }

    // MARK: - Helpers

    private func sample(given: String?, family: String?, full: String?) -> IDDocumentData {
        IDDocumentData(
            documentType: nil, documentNumber: nil,
            givenName: given, familyName: family, fullName: full,
            dateOfBirth: nil, sex: nil, nationality: nil,
            issuingAuthority: nil, issueDate: nil, expiryDate: nil,
            address: nil, mrz: nil,
            additionalFields: []
        )
    }

    private struct Decoded: Decodable {
        let additionalFields: [IDField]
    }
}
