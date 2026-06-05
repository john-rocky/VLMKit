import XCTest
@testable import VLMKit

/// Logic-only tests for `Receipt` — the deterministic shaping between the raw
/// model output and the public `ReceiptData`, plus CSV escaping. No model or GPU.
final class ReceiptTests: XCTestCase {

    // MARK: - JSONNumber tolerant decode

    /// Bare JSON number: the common case the prompt asks for.
    func testJSONNumberDecodesBareNumber() throws {
        let value = try decodeJSONNumber("1280")
        XCTAssertEqual(value.doubleValue, 1280)
    }

    func testJSONNumberDecodesBareFraction() throws {
        let value = try decodeJSONNumber("12.5")
        XCTAssertEqual(value.doubleValue, 12.5)
    }

    /// Quoted number: model occasionally pads with commas/symbols. Strip and parse.
    /// Locale: US-style decimal point. European decimal-comma ("1.234,56") is not
    /// supported — pin the prompt to a single convention rather than guess.
    func testJSONNumberDecodesQuotedFormattedAmount() throws {
        XCTAssertEqual(try decodeJSONNumber("\"¥1,280\"").doubleValue, 1280)
        XCTAssertEqual(try decodeJSONNumber("\"$12.50\"").doubleValue, 12.50)
        XCTAssertEqual(try decodeJSONNumber("\"1,234\"").doubleValue, 1234)
        XCTAssertEqual(try decodeJSONNumber("\"$1,234.56\"").doubleValue, 1234.56)
    }

    /// Negative amounts (refund, discount) — keep the sign.
    func testJSONNumberDecodesNegative() throws {
        XCTAssertEqual(try decodeJSONNumber("-200").doubleValue, -200)
        XCTAssertEqual(try decodeJSONNumber("\"-¥200\"").doubleValue, -200)
    }

    // MARK: - clean()

    func testCleanTrimsAndCollapsesBlanks() {
        let raw = Receipt.ReceiptRaw(
            merchant: "  Starbucks  ",
            date: "  ",
            currency: "JPY",
            total: .number(480),
            subtotal: nil,
            tax: nil,
            paymentMethod: nil,
            category: nil,
            items: nil
        )
        let cleaned = Receipt.clean(raw)
        XCTAssertEqual(cleaned.merchant, "Starbucks")
        XCTAssertNil(cleaned.date)         // blank → nil
        XCTAssertEqual(cleaned.currency, "JPY")
        XCTAssertEqual(cleaned.total, 480)
        XCTAssertTrue(cleaned.items.isEmpty)
    }

    func testCleanDropsItemsWithoutName() {
        let raw = Receipt.ReceiptRaw(
            merchant: "Cafe",
            date: nil, currency: nil,
            total: nil, subtotal: nil, tax: nil,
            paymentMethod: nil, category: nil,
            items: [
                .init(name: "Latte", quantity: .number(1), amount: .number(480)),
                .init(name: "  ", quantity: nil, amount: .number(0)),
                .init(name: nil, quantity: nil, amount: nil),
                .init(name: "Cookie", quantity: nil, amount: .number(200)),
            ]
        )
        let cleaned = Receipt.clean(raw)
        XCTAssertEqual(cleaned.items.map(\.name), ["Latte", "Cookie"])
        XCTAssertEqual(cleaned.items[0].amount, 480)
        XCTAssertEqual(cleaned.items[1].amount, 200)
    }

    func testCleanSnapsCategoryCaseInsensitively() {
        XCTAssertEqual(Receipt.normalizeCategory("meals"), "Meals")
        XCTAssertEqual(Receipt.normalizeCategory("  TRANSPORTATION "), "Transportation")
        XCTAssertEqual(Receipt.normalizeCategory("Other"), "Other")
    }

    func testCleanDropsUnknownCategory() {
        XCTAssertNil(Receipt.normalizeCategory("Random Made-Up"))
        XCTAssertNil(Receipt.normalizeCategory(""))
        XCTAssertNil(Receipt.normalizeCategory("   "))
    }

    func testCleanParsesQuotedNumbers() {
        let raw = Receipt.ReceiptRaw(
            merchant: "Bar",
            date: nil, currency: "JPY",
            total: .string("¥1,280"),
            subtotal: .string("1,200"),
            tax: .number(80),
            paymentMethod: nil, category: nil,
            items: nil
        )
        let cleaned = Receipt.clean(raw)
        XCTAssertEqual(cleaned.total, 1280)
        XCTAssertEqual(cleaned.subtotal, 1200)
        XCTAssertEqual(cleaned.tax, 80)
    }

    // MARK: - CSV escaping

    func testCSVEscapeLeavesSafeStringsAlone() {
        XCTAssertEqual(Receipt.csvEscape("Starbucks"), "Starbucks")
        XCTAssertEqual(Receipt.csvEscape("2026-06-02"), "2026-06-02")
    }

    func testCSVEscapeQuotesValuesWithDelimiters() {
        XCTAssertEqual(Receipt.csvEscape("Latte, Cookie"), "\"Latte, Cookie\"")
        XCTAssertEqual(Receipt.csvEscape("Line1\nLine2"), "\"Line1\nLine2\"")
    }

    /// Embedded quotes are doubled per RFC 4180.
    func testCSVEscapeDoublesEmbeddedQuotes() {
        XCTAssertEqual(Receipt.csvEscape(#"He said "hi""#), #""He said ""hi"""""#)
    }

    func testCSVEscapeBlankBecomesEmpty() {
        XCTAssertEqual(Receipt.csvEscape(nil), "")
        XCTAssertEqual(Receipt.csvEscape(""), "")
    }

    // MARK: - numberString

    func testNumberStringIntegersHaveNoDecimal() {
        XCTAssertEqual(Receipt.numberString(480), "480")
        XCTAssertEqual(Receipt.numberString(-200), "-200")
    }

    func testNumberStringFractionsUseTwoDecimals() {
        XCTAssertEqual(Receipt.numberString(12.5), "12.50")
        XCTAssertEqual(Receipt.numberString(0.07), "0.07")
    }

    func testNumberStringNilIsEmpty() {
        XCTAssertEqual(Receipt.numberString(nil), "")
    }

    // MARK: - csvRow / csv

    func testCSVRowProducesExpectedColumns() {
        let receipt = ReceiptData(
            merchant: "Starbucks",
            date: "2026-06-02",
            currency: "JPY",
            total: 480,
            subtotal: 440,
            tax: 40,
            paymentMethod: "Credit Card",
            category: "Meals",
            items: [
                .init(name: "Latte", quantity: 1, amount: 480)
            ]
        )
        XCTAssertEqual(
            Receipt.csvRow(receipt),
            "Starbucks,2026-06-02,JPY,480,440,40,Credit Card,Meals,Latte ×1 (480)"
        )
    }

    func testCSVRowEscapesItemsWithSemicolons() {
        let receipt = ReceiptData(
            merchant: "Cafe, Tokyo",  // comma in merchant
            date: nil, currency: nil,
            total: nil, subtotal: nil, tax: nil,
            paymentMethod: nil, category: nil,
            items: [
                .init(name: "Latte", quantity: nil, amount: 480),
                .init(name: "Cookie", quantity: nil, amount: 200),
            ]
        )
        let row = Receipt.csvRow(receipt)
        // Items cell contains "; " so it must be quoted; merchant has "," so quoted too.
        XCTAssertTrue(row.contains("\"Cafe, Tokyo\""))
        XCTAssertTrue(row.contains("\"Latte (480); Cookie (200)\""))
    }

    func testCSVIncludesHeader() {
        let receipt = ReceiptData(
            merchant: "X", date: nil, currency: nil,
            total: nil, subtotal: nil, tax: nil,
            paymentMethod: nil, category: nil,
            items: []
        )
        let csv = Receipt.csv(receipt)
        XCTAssertTrue(csv.hasPrefix(Receipt.csvHeader + "\n"))
        XCTAssertTrue(csv.hasSuffix(Receipt.csvRow(receipt)))
    }

    // MARK: - Helpers

    private func decodeJSONNumber(_ json: String) throws -> JSONNumber {
        try JSONDecoder().decode(JSONNumber.self, from: Data(json.utf8))
    }
}
