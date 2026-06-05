import CoreGraphics
import Foundation
import VLMKit

/// Maps the schema-driven recipes' typed extractions (Receipt / Business Card /
/// ID) onto `[Detection]` so the photo spotlight overlay + auto-tour just work:
/// tapping a row in the card highlights its location on the photo, the model's
/// reading is callout-typed beside the box, the tour walks the values in card
/// order.
///
/// Each value is grounded via `OCRProvider.locate` over the page's OCR
/// observations, with a small list of printed-vs-parsed candidates so e.g. a
/// total of `1280` matches a receipt printed as "1,280" or "¥1,280". Values
/// that don't match any OCR span are simply omitted from the detections — the
/// card still renders that row, it just has no photo box to spotlight.
enum SchemaGrounding {
    // MARK: - Receipt

    /// Detections in receipt-card order: merchant, date, total, subtotal, tax,
    /// payment, then each line item. Currency-aware amount text in the callout
    /// detail (so the spotlight reads "¥1,280" not bare "1280"). Category is
    /// skipped on purpose — it is inferred by the VLM and not always printed.
    static func detections(
        for data: ReceiptData,
        observations: [OCRObservation]
    ) -> [Detection] {
        var detections: [Detection] = []
        func append(_ key: String, _ label: String, _ detail: String, candidates: [String]) {
            guard let box = OCRProvider.locate(candidates, in: observations) else { return }
            detections.append(Detection(key: key, label: label, detail: detail, box: box))
        }

        if let merchant = data.merchant {
            append("receipt-merchant", "Merchant", merchant, candidates: [merchant])
        }
        if let date = data.date {
            append("receipt-date", "Date", date, candidates: [date])
        }
        if let total = data.total {
            append("receipt-total", "Total",
                   amountText(total, currency: data.currency),
                   candidates: numberCandidates(total))
        }
        if let subtotal = data.subtotal {
            append("receipt-subtotal", "Subtotal",
                   amountText(subtotal, currency: data.currency),
                   candidates: numberCandidates(subtotal))
        }
        if let tax = data.tax {
            append("receipt-tax", "Tax",
                   amountText(tax, currency: data.currency),
                   candidates: numberCandidates(tax))
        }
        if let payment = data.paymentMethod {
            append("receipt-payment", "Payment", payment, candidates: [payment])
        }
        for (index, item) in data.items.enumerated() {
            // Prefer the item name as the anchor (each line typically reads
            // "<name> ... <amount>", so the name box localizes the whole row);
            // fall back to the amount if the name didn't match (truncated /
            // abbreviated names on busy receipts).
            var candidates: [String] = [item.name]
            if let amount = item.amount { candidates.append(contentsOf: numberCandidates(amount)) }
            let detail = lineItemDetail(item, currency: data.currency)
            append("receipt-item-\(index)", item.name, detail, candidates: candidates)
        }
        return detections
    }

    /// Line-item callout body: "×qty · ¥amount" / "¥amount" / "×qty" / "" —
    /// whichever pieces the model could read. Mirrors the receipt-card row.
    private static func lineItemDetail(_ item: ReceiptLineItem, currency: String?) -> String {
        var parts: [String] = []
        if let q = item.quantity { parts.append("×\(numberString(q))") }
        if let a = item.amount { parts.append(amountText(a, currency: currency)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Business Card

    /// Detections in card order: name, phonetic, title/company, each phone,
    /// each email, each URL, address, each social. Multi-line address only
    /// matches when it fits on a single OCR line — falls through silently
    /// otherwise (the row renders without a photo highlight).
    static func detections(
        for data: BusinessCardData,
        observations: [OCRObservation]
    ) -> [Detection] {
        var detections: [Detection] = []
        func append(_ key: String, _ label: String, _ detail: String, candidates: [String]) {
            guard let box = OCRProvider.locate(candidates, in: observations) else { return }
            detections.append(Detection(key: key, label: label, detail: detail, box: box))
        }

        // Name: try printed full name first, then assembled split-name in both
        // orders (Japanese cards print family-first, Western cards given-first).
        let nameCandidates: [String] = {
            var c: [String] = []
            if let full = data.fullName { c.append(full) }
            if let g = data.givenName, let f = data.familyName {
                c.append("\(f) \(g)")
                c.append("\(g) \(f)")
            }
            if let g = data.givenName { c.append(g) }
            if let f = data.familyName { c.append(f) }
            return c
        }()
        if !nameCandidates.isEmpty {
            append("card-name", "Name", data.displayName, candidates: nameCandidates)
        }
        if let phonetic = data.phoneticName {
            append("card-phonetic", "Phonetic", phonetic, candidates: [phonetic])
        }
        if let title = data.title {
            append("card-title", "Title", title, candidates: [title])
        }
        if let company = data.company {
            append("card-company", "Company", company, candidates: [company])
        }
        if let department = data.department {
            append("card-department", "Department", department, candidates: [department])
        }
        for (index, phone) in data.phones.enumerated() {
            // Phone numbers are often printed with separators ("03-1234-5678"
            // vs parsed "0312345678" vs spaced). Try as-is and a digits-only
            // form so both representations match.
            let digits = phone.number.filter(\.isNumber)
            let candidates = digits == phone.number ? [phone.number] : [phone.number, digits]
            append("card-phone-\(index)", phone.kind ?? "Phone", phone.number, candidates: candidates)
        }
        for (index, email) in data.emails.enumerated() {
            append("card-email-\(index)", "Email", email, candidates: [email])
        }
        for (index, url) in data.urls.enumerated() {
            append("card-url-\(index)", "Web", url, candidates: [url])
        }
        if let address = data.address {
            // The recipe joins multi-line addresses with commas; the OCR sees
            // them line-by-line. Try the whole string (single-line printings
            // hit), then the first comma-separated chunk (typically the street).
            var candidates: [String] = [address]
            if let firstChunk = address.split(separator: ",").first.map(String.init) {
                candidates.append(firstChunk)
            }
            append("card-address", "Address", address, candidates: candidates)
        }
        for (index, social) in data.socials.enumerated() {
            append("card-social-\(index)", social.platform, social.handle, candidates: [social.handle])
        }
        return detections
    }

    // MARK: - ID Document

    /// Detections in card order: face (when Vision found one), document
    /// number, holder name, DOB, nationality, dates, issuing authority,
    /// address, MRZ, additional fields. Sex (single char "M"/"F") is skipped
    /// — too short to disambiguate reliably from other letters on the page.
    /// `faceBox` is the Vision face detection's normalized rect (0...1,
    /// top-left), or nil when no face was found.
    static func detections(
        for data: IDDocumentData,
        observations: [OCRObservation],
        faceBox: CGRect?
    ) -> [Detection] {
        var detections: [Detection] = []
        func append(_ key: String, _ label: String, _ detail: String, candidates: [String]) {
            guard let box = OCRProvider.locate(candidates, in: observations) else { return }
            detections.append(Detection(key: key, label: label, detail: detail, box: box))
        }

        if let faceBox {
            // Face is grounded by Vision, not OCR — drop straight into detections.
            detections.append(Detection(
                key: "id-face", label: "Holder",
                detail: data.displayName.isEmpty ? "Photo" : data.displayName,
                box: faceBox
            ))
        }
        if let number = data.documentNumber {
            append("id-number", "Document No.", number, candidates: [number])
        }
        // Name: try fullName, both split orders, and each part separately.
        let nameCandidates: [String] = {
            var c: [String] = []
            if let full = data.fullName { c.append(full) }
            if let g = data.givenName, let f = data.familyName {
                c.append("\(f) \(g)")
                c.append("\(g) \(f)")
            }
            if let f = data.familyName { c.append(f) }
            if let g = data.givenName { c.append(g) }
            return c
        }()
        if !nameCandidates.isEmpty, !data.displayName.isEmpty {
            append("id-name", "Name", data.displayName, candidates: nameCandidates)
        }
        if let dob = data.dateOfBirth {
            append("id-dob", "Date of birth", dob, candidates: [dob])
        }
        if let nationality = data.nationality {
            append("id-nationality", "Nationality", nationality, candidates: [nationality])
        }
        if let issued = data.issueDate {
            append("id-issued", "Issued", issued, candidates: [issued])
        }
        if let expiry = data.expiryDate {
            append("id-expires", "Expires", expiry, candidates: [expiry])
        }
        if let authority = data.issuingAuthority {
            // Issuing authorities are often long and span multiple OCR lines.
            // Try the full string, then the first comma-chunk.
            var candidates: [String] = [authority]
            if let firstChunk = authority.split(separator: ",").first.map(String.init) {
                candidates.append(firstChunk)
            }
            append("id-authority", "Issuing authority", authority, candidates: candidates)
        }
        if let address = data.address {
            var candidates: [String] = [address]
            if let firstChunk = address.split(separator: ",").first.map(String.init) {
                candidates.append(firstChunk)
            }
            append("id-address", "Address", address, candidates: candidates)
        }
        if let mrz = data.mrz {
            // MRZ wraps over 2–3 lines; OCR sees each line. Try the first line
            // as the anchor — the spotlight ends up on the top MRZ row, good
            // enough to point at "the MRZ block".
            let firstLine = mrz.split(whereSeparator: \.isNewline).first.map(String.init) ?? mrz
            append("id-mrz", "MRZ", mrz, candidates: [firstLine, mrz])
        }
        for (index, field) in data.additionalFields.enumerated() {
            append("id-extra-\(index)", field.label, field.value, candidates: [field.value])
        }
        return detections
    }

    // MARK: - Formatting helpers

    /// Bare integer ("1280") and thousands-grouped form ("1,280") — covers the
    /// two common ways an amount is printed on a receipt vs the parsed value.
    /// Fractional values use two decimals ("12.50"), the rounded integer form,
    /// and the comma form of the integer for receipts that print "$13".
    private static func numberCandidates(_ value: Double) -> [String] {
        if value == value.rounded() {
            let int = Int(value)
            let bare = String(int)
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let grouped = formatter.string(from: NSNumber(value: int)) ?? bare
            return bare == grouped ? [bare] : [bare, grouped]
        }
        // Fractional: "12.50" and its rounded integer "13" (some receipts
        // round on the printed line).
        let fmt = String(format: "%.2f", value)
        let rounded = String(Int(value.rounded()))
        return [fmt, rounded]
    }

    /// Receipt amount as displayed in the callout: ISO currency code prefix
    /// when known ("¥1,280" / "$12.50"), bare amount otherwise. Used for the
    /// spotlight callout detail, not for grounding.
    private static func amountText(_ value: Double, currency: String?) -> String {
        let amount = numberString(value)
        guard let symbol = currencySymbol(currency) else { return amount }
        return "\(symbol)\(amount)"
    }

    /// Map ISO codes to their printed symbols; pass through unknown codes
    /// verbatim. Kept small — the receipts that work on-device cover the codes
    /// the model emits ("JPY"/"USD"/"EUR"/"GBP"/"CNY"/"KRW").
    static func currencySymbol(_ code: String?) -> String? {
        guard let code = code?.uppercased(), !code.isEmpty else { return nil }
        switch code {
        case "JPY", "CNY", "RMB": return "¥"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "KRW": return "₩"
        default: return code + " "
        }
    }

    /// Integer-valued doubles render without a decimal ("480"), fractional
    /// values with two decimals ("12.50"). Comma-grouped for the integer side
    /// so the callout reads as a printed amount, not a raw number.
    static func numberString(_ value: Double) -> String {
        if value == value.rounded() {
            let int = Int(value)
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            return formatter.string(from: NSNumber(value: int)) ?? String(int)
        }
        return String(format: "%.2f", value)
    }
}
