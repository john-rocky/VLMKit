import Foundation

/// Structured data read off a printed receipt. Fixed schema (vs. `DocumentQA`'s
/// open key/value pairs) so the caller can type-check the totals, do math, and
/// export to CSV without further parsing. Every field is optional: receipts vary
/// wildly, and `nil` is more honest than a hallucinated value.
public struct ReceiptData: Sendable, Equatable {
    public let merchant: String?
    /// `YYYY-MM-DD` when the model can normalize it; the raw printed string
    /// otherwise. Callers that need a `Date` should parse defensively.
    public let date: String?
    /// ISO 4217 code ("JPY", "USD", "EUR") when recognizable; raw symbol/word
    /// from the receipt otherwise.
    public let currency: String?
    public let total: Double?
    public let subtotal: Double?
    public let tax: Double?
    /// As printed: "Cash", "Credit Card", "Visa", "QR", … `nil` when not shown.
    public let paymentMethod: String?
    /// One of `Receipt.knownCategories`, snapped from the model's free-text choice.
    /// `nil` when ambiguous.
    public let category: String?
    public let items: [ReceiptLineItem]

    public init(
        merchant: String?,
        date: String?,
        currency: String?,
        total: Double?,
        subtotal: Double?,
        tax: Double?,
        paymentMethod: String?,
        category: String?,
        items: [ReceiptLineItem]
    ) {
        self.merchant = merchant
        self.date = date
        self.currency = currency
        self.total = total
        self.subtotal = subtotal
        self.tax = tax
        self.paymentMethod = paymentMethod
        self.category = category
        self.items = items
    }
}

public struct ReceiptLineItem: Sendable, Equatable {
    public let name: String
    public let quantity: Double?
    public let amount: Double?

    public init(name: String, quantity: Double?, amount: Double?) {
        self.name = name
        self.quantity = quantity
        self.amount = amount
    }
}

/// Receipt extraction — one VLM call per receipt against a fixed schema, then a
/// CSV row for export. Builds on the same Vision-OCR grounding story as
/// `DocumentQA` (the app can OCR the same image and box each value) but trades
/// open-ended key/value pairs for typed fields you can sum, sort, and audit.
///
/// On-device only. No FinanceKit write (that entitlement is restricted to
/// Apple-approved banking apps); CSV export lets users hand off to whatever
/// expense system they already use.
public enum Receipt {
    /// The category buckets the model is asked to snap to. Kept small so the
    /// distribution is predictable; downstream categorization can refine.
    public static let knownCategories: [String] = [
        "Meals",
        "Transportation",
        "Lodging",
        "Office Supplies",
        "Entertainment",
        "Utilities",
        "Other",
    ]

    /// Extract structured receipt data from a single receipt image. One VLM call,
    /// schema-driven prompt. Numbers come back as `Double` (or `nil` when the
    /// field is missing/illegible) — currency symbols and thousands separators
    /// in the model's output are tolerated via the raw-decode wrapper.
    public static func extract(
        on image: VLMImage,
        runner: VLMRunner
    ) async throws -> ReceiptData {
        let task = VLMTask<ReceiptRaw>(
            instruction: """
            You are reading a printed receipt — restaurant bill, store receipt, \
            ride receipt, hotel folio, anything with merchant / date / total. \
            Extract the fields below. Use null for any field you cannot read \
            with confidence — do NOT guess.

            Rules:
            - "merchant": the business name as printed (e.g. "Starbucks Roppongi").
            - "date": YYYY-MM-DD if you can normalize from the printed date; \
            otherwise the raw printed date string. Null if no date is shown.
            - "currency": ISO 4217 code if recognizable ("JPY" for ¥, "USD" for \
            $, "EUR" for €, "GBP" for £). Null when unclear.
            - "total" / "subtotal" / "tax": numbers only, no symbols, no commas. \
            "¥1,280" becomes 1280, "$12.50" becomes 12.5. Null when the receipt \
            does not show that field.
            - "paymentMethod": as printed (e.g. "Cash", "Credit Card", "Visa", \
            "QR Pay"). Null when not shown.
            - "category": one of \(knownCategories.joined(separator: ", ")). \
            Pick the closest based on merchant and items. Null only when truly \
            ambiguous.
            - "items": each printed line item with its name and, when shown, its \
            quantity and amount. Skip subtotal / tax / total rows themselves.

            Output a single JSON object in the shape specified.
            """,
            jsonHint: #"""
            {"merchant": "string or null", "date": "string or null", "currency": "string or null", "total": 0, "subtotal": 0, "tax": 0, "paymentMethod": "string or null", "category": "string or null", "items": [{"name": "string", "quantity": 0, "amount": 0}]}
            """#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        return clean(try await runner.run(task, images: [image]))
    }

    // MARK: - Internal: raw model output + cleanup

    /// What the model actually returns. Numeric fields go through `JSONNumber`
    /// so a model that quotes "1,280" or "¥480" instead of emitting a bare
    /// number still decodes. Mapped to the typed `ReceiptData` by `clean`.
    struct ReceiptRaw: Codable, Sendable {
        let merchant: String?
        let date: String?
        let currency: String?
        let total: JSONNumber?
        let subtotal: JSONNumber?
        let tax: JSONNumber?
        let paymentMethod: String?
        let category: String?
        let items: [ItemRaw]?

        struct ItemRaw: Codable, Sendable {
            let name: String?
            let quantity: JSONNumber?
            let amount: JSONNumber?
        }
    }

    /// Trim strings, parse the tolerant numeric wrappers, drop blank items, and
    /// snap the model's free-text category to one of the known buckets.
    /// Internal so tests can pin the shape.
    static func clean(_ raw: ReceiptRaw) -> ReceiptData {
        let items: [ReceiptLineItem] = (raw.items ?? []).compactMap { item in
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return ReceiptLineItem(
                name: name,
                quantity: item.quantity?.doubleValue,
                amount: item.amount?.doubleValue
            )
        }
        return ReceiptData(
            merchant: raw.merchant.nilIfBlank,
            date: raw.date.nilIfBlank,
            currency: raw.currency.nilIfBlank,
            total: raw.total?.doubleValue,
            subtotal: raw.subtotal?.doubleValue,
            tax: raw.tax?.doubleValue,
            paymentMethod: raw.paymentMethod.nilIfBlank,
            category: raw.category.flatMap(normalizeCategory),
            items: items
        )
    }

    /// Snap the model's free-text category to one of `knownCategories`
    /// case-insensitively. Returns `nil` for an unknown / blank value.
    static func normalizeCategory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        return knownCategories.first { $0.lowercased() == lower }
    }

    // MARK: - CSV export

    /// CSV header row — column names are stable so users can append exported
    /// receipts to a spreadsheet over time without column drift.
    public static let csvHeader =
        "Merchant,Date,Currency,Total,Subtotal,Tax,Payment Method,Category,Items"

    /// CSV row for a single receipt, matching `csvHeader`'s columns. Items are
    /// flattened into one cell: `"Latte ×1 (480); Cookie (200)"`. For a multi-
    /// row itemized export the caller can build one row per `ReceiptLineItem`.
    public static func csvRow(_ receipt: ReceiptData) -> String {
        let itemsCell = receipt.items.map { item -> String in
            switch (item.quantity, item.amount) {
            case let (q?, a?): "\(item.name) ×\(numberString(q)) (\(numberString(a)))"
            case let (nil, a?): "\(item.name) (\(numberString(a)))"
            case let (q?, nil): "\(item.name) ×\(numberString(q))"
            case (nil, nil): item.name
            }
        }.joined(separator: "; ")
        return [
            csvEscape(receipt.merchant),
            csvEscape(receipt.date),
            csvEscape(receipt.currency),
            numberString(receipt.total),
            numberString(receipt.subtotal),
            numberString(receipt.tax),
            csvEscape(receipt.paymentMethod),
            csvEscape(receipt.category),
            csvEscape(itemsCell),
        ].joined(separator: ",")
    }

    /// Header + one row, ready to write to a `.csv` file or paste into Numbers.
    public static func csv(_ receipt: ReceiptData) -> String {
        "\(csvHeader)\n\(csvRow(receipt))"
    }

    /// RFC 4180-ish escape: wrap in quotes when the value contains a comma, a
    /// quote, or a newline; double up any embedded quotes. `nil` / empty
    /// becomes an empty cell.
    static func csvEscape(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let needsQuoting = value.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Integer-valued doubles render without a decimal ("480"), fractional
    /// values use two decimals ("12.50"). `nil` becomes empty.
    static func numberString(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }
}

/// JSON value that accepts a bare number ("total": 1280) OR a quoted string
/// ("total": "¥1,280") and parses both to `Double`. VLMs occasionally quote
/// numbers — especially when they're formatted with currency symbols or
/// thousands separators — so we accept either and strip the noise.
enum JSONNumber: Codable, Sendable {
    case number(Double)
    case string(String)

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let raw):
            // Strip common currency symbols, thousands separators, and stray
            // whitespace before parsing. Keep the decimal point.
            let stripped = raw.unicodeScalars
                .filter { scalar in
                    let c = Character(scalar)
                    return c.isNumber || c == "." || c == "-"
                }
                .reduce(into: "") { $0.append(Character($1)) }
            return Double(stripped)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            throw DecodingError.valueNotFound(
                JSONNumber.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Null where number/string expected")
            )
        }
        if let d = try? container.decode(Double.self) {
            self = .number(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        throw DecodingError.typeMismatch(
            JSONNumber.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected number or string")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        }
    }
}

private extension Optional where Wrapped == String {
    /// Trim whitespace and collapse empty/whitespace-only strings to `nil`.
    var nilIfBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}
