import XCTest
@testable import VLMKit

/// Logic-only tests for `Listing` — deterministic shaping between the raw
/// model output and the typed `ListingData`. No model or GPU involved.
final class ListingTests: XCTestCase {

    // MARK: - clean()

    func testCleanTrimsScalarFields() {
        let raw = Listing.ListingRaw(
            title: "  Vintage Jacket  ",
            description: "  Soft fleece lining.\n",
            features: nil,
            condition: nil,
            suggestedPriceRange: "  ¥3,000 - 5,000  ",
            tags: nil,
            altText: "  A red jacket on a chair  "
        )
        let cleaned = Listing.clean(raw)
        XCTAssertEqual(cleaned.title, "Vintage Jacket")
        XCTAssertEqual(cleaned.description, "Soft fleece lining.")
        XCTAssertEqual(cleaned.suggestedPriceRange, "¥3,000 - 5,000")
        XCTAssertEqual(cleaned.altText, "A red jacket on a chair")
    }

    func testCleanCollapsesBlankScalarsToNil() {
        let raw = Listing.ListingRaw(
            title: "   ",
            description: "",
            features: nil,
            condition: "  ",
            suggestedPriceRange: nil,
            tags: nil,
            altText: ""
        )
        let cleaned = Listing.clean(raw)
        XCTAssertNil(cleaned.title)
        XCTAssertNil(cleaned.description)
        XCTAssertNil(cleaned.condition)
        XCTAssertNil(cleaned.altText)
    }

    func testCleanCapsAndTrimsFeatures() {
        let manyFeatures = (1...20).map { "Feature \($0)" }
        let raw = Listing.ListingRaw(
            title: nil, description: nil,
            features: ["  First  ", "", "Second", "  ", "Third"] + manyFeatures,
            condition: nil, suggestedPriceRange: nil, tags: nil, altText: nil
        )
        let cleaned = Listing.clean(raw)
        // Cap at 7. Order preserved. Blanks skipped.
        XCTAssertEqual(cleaned.features.count, 7)
        XCTAssertEqual(cleaned.features.prefix(3), ["First", "Second", "Third"])
    }

    func testCleanLowercasesAndDedupesTags() {
        let raw = Listing.ListingRaw(
            title: nil, description: nil, features: nil,
            condition: nil, suggestedPriceRange: nil,
            tags: ["Vintage", "vintage", "  VINTAGE  ", "Wool", "Red", "red", "Jacket"],
            altText: nil
        )
        let cleaned = Listing.clean(raw)
        XCTAssertEqual(cleaned.tags, ["vintage", "wool", "red", "jacket"])
    }

    func testCleanCapsTagsAtTen() {
        let raw = Listing.ListingRaw(
            title: nil, description: nil, features: nil,
            condition: nil, suggestedPriceRange: nil,
            tags: (1...20).map { "tag\($0)" },
            altText: nil
        )
        let cleaned = Listing.clean(raw)
        XCTAssertEqual(cleaned.tags.count, 10)
    }

    // MARK: - normalizeCondition()

    func testNormalizeConditionSnapsKnown() {
        XCTAssertEqual(Listing.normalizeCondition("New"), "New")
        XCTAssertEqual(Listing.normalizeCondition("like new"), "Like New")
        XCTAssertEqual(Listing.normalizeCondition("  USED - GOOD  "), "Used - Good")
    }

    func testNormalizeConditionMapsSynonyms() {
        XCTAssertEqual(Listing.normalizeCondition("Mint"), "New")
        XCTAssertEqual(Listing.normalizeCondition("Excellent"), "Like New")
        XCTAssertEqual(Listing.normalizeCondition("Good"), "Used - Good")
        XCTAssertEqual(Listing.normalizeCondition("Fair"), "Used - Fair")
        XCTAssertEqual(Listing.normalizeCondition("Worn"), "Used - Heavy Wear")
        XCTAssertEqual(Listing.normalizeCondition("for parts only"), "For Parts")
    }

    func testNormalizeConditionPreservesUnknown() {
        XCTAssertEqual(Listing.normalizeCondition("Vintage Patina"), "Vintage Patina")
    }

    func testNormalizeConditionBlankIsNil() {
        XCTAssertNil(Listing.normalizeCondition("   "))
    }

    // MARK: - JSON

    func testJSONIncludesEveryKey() throws {
        let data = ListingData(
            title: "Vintage Jacket",
            description: "Soft fleece.",
            features: ["Warm", "Light"],
            condition: "Like New",
            suggestedPriceRange: "¥3,000 - 5,000",
            tags: ["vintage", "warm"],
            altText: "A red vintage jacket."
        )
        let json = try Listing.json(data)
        for key in ["title", "description", "features", "condition",
                    "suggestedPriceRange", "tags", "altText"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "JSON missing key \(key)")
        }
    }

    func testJSONEncodesNullsForMissing() throws {
        let data = ListingData(
            title: nil, description: nil,
            features: [],
            condition: nil, suggestedPriceRange: nil,
            tags: [],
            altText: nil
        )
        let json = try Listing.json(data)
        XCTAssertTrue(json.contains("\"title\" : null"))
        XCTAssertTrue(json.contains("\"description\" : null"))
        XCTAssertTrue(json.contains("\"condition\" : null"))
    }
}
