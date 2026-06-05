import Foundation

/// Structured data read off an identity document — passport, driver's license,
/// national ID, residence card, insurance card, student ID, etc. Fixed schema
/// of common KYC fields, optional everywhere because no single document type
/// fills every slot. Anything that doesn't fit the schema lives in
/// `additionalFields` so the caller still sees it (vehicle classes on a DL,
/// restrictions, blood type, etc.).
///
/// On-device only: this recipe never sends pixels off the phone, which is the
/// whole point for IDs. Callers should reinforce that promise in their UI.
public struct IDDocumentData: Sendable, Equatable {
    /// "Passport" / "Driver's License" / "National ID" / "Residence Card" / …
    /// Normalized to one of `IDDocument.knownDocumentTypes` when recognizable.
    public let documentType: String?
    public let documentNumber: String?
    public let givenName: String?
    public let familyName: String?
    /// Raw printed full name. Fallback when the model can't split into given/family.
    public let fullName: String?
    /// `YYYY-MM-DD` when the model normalizes; raw printed string otherwise.
    public let dateOfBirth: String?
    /// "M" / "F" / "X" or as printed.
    public let sex: String?
    /// ISO 3166-1 alpha-3 ("USA", "JPN") when recognizable; raw otherwise.
    public let nationality: String?
    public let issuingAuthority: String?
    public let issueDate: String?
    public let expiryDate: String?
    /// Driver's licenses and some national IDs print the holder's address.
    public let address: String?
    /// Raw MRZ (Machine-Readable Zone) for passports — the two/three lines of
    /// `<<<` separated codes at the bottom. Preserved verbatim so downstream
    /// validators (check-digit, country code, name parse) can run on it.
    public let mrz: String?
    /// Anything not covered above: vehicle classes, restrictions, blood type,
    /// student ID expiry, residence status, etc. Order preserved from the model.
    public let additionalFields: [IDField]

    public init(
        documentType: String?,
        documentNumber: String?,
        givenName: String?,
        familyName: String?,
        fullName: String?,
        dateOfBirth: String?,
        sex: String?,
        nationality: String?,
        issuingAuthority: String?,
        issueDate: String?,
        expiryDate: String?,
        address: String?,
        mrz: String?,
        additionalFields: [IDField]
    ) {
        self.documentType = documentType
        self.documentNumber = documentNumber
        self.givenName = givenName
        self.familyName = familyName
        self.fullName = fullName
        self.dateOfBirth = dateOfBirth
        self.sex = sex
        self.nationality = nationality
        self.issuingAuthority = issuingAuthority
        self.issueDate = issueDate
        self.expiryDate = expiryDate
        self.address = address
        self.mrz = mrz
        self.additionalFields = additionalFields
    }

    /// Best display name: split parts joined, falling back to full or either part.
    public var displayName: String {
        if let given = givenName, let family = familyName {
            return "\(given) \(family)"
        }
        return fullName ?? givenName ?? familyName ?? ""
    }
}

public struct IDField: Sendable, Equatable, Codable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// ID-document extraction — one VLM call against a fixed KYC schema. Schema-
/// driven prompt means more reliable extraction than open-ended DocumentQA on
/// the receipt-of-this-particular-shape problem, and the typed output drops
/// straight into a fintech / regulated-industry app's own data model.
public enum IDDocument {
    /// Document types we ask the model to snap to. Free text from the model
    /// that doesn't match falls through as-is (better than dropping novel ID
    /// types).
    public static let knownDocumentTypes: [String] = [
        "Passport",
        "Driver's License",
        "National ID",
        "Residence Card",
        "Insurance Card",
        "Student ID",
        "Employee ID",
        "Other",
    ]

    /// Extract structured ID-document data from a single image.
    public static func extract(
        on image: VLMImage,
        runner: VLMRunner
    ) async throws -> IDDocumentData {
        let task = VLMTask<IDRaw>(
            instruction: """
            You are reading an identity document — passport, driver's license, \
            national ID, residence card, insurance card, employee/student ID, \
            or similar. Extract the fields below from what is printed. Use null \
            for any field you cannot read with confidence — do NOT guess.

            Rules:
            - "documentType": one of \(knownDocumentTypes.joined(separator: ", ")). \
            Pick the closest match. Null only when ambiguous.
            - "documentNumber": the primary identifying number printed on the \
            document (passport number, DL number, ID number). Keep punctuation \
            and casing exactly as printed.
            - "givenName" / "familyName": split the printed name. If split is \
            unclear, leave both null and put the full name in "fullName".
            - "fullName": raw printed full name when split fails. Otherwise null.
            - "dateOfBirth" / "issueDate" / "expiryDate": YYYY-MM-DD if you can \
            normalize from the printed date; otherwise the raw printed date \
            string. Null if not shown.
            - "sex": "M", "F", "X", or as printed. Null if not shown.
            - "nationality": ISO 3166-1 alpha-3 ("USA", "JPN", "DEU") when \
            recognizable; raw printed nationality otherwise. Null if not shown.
            - "issuingAuthority": the authority printed on the document \
            ("Department of State", "Tokyo Metropolitan Public Safety \
            Commission", "DMV California"). Null if not shown.
            - "address": the holder's printed address as a single string, \
            joined with commas if printed across multiple lines. Null when not \
            shown (most passports do not show address).
            - "mrz": for passports / IDs with a Machine-Readable Zone (the \
            block of OCR-A `<` symbols, typically at the bottom), include the \
            full MRZ verbatim with literal newlines between lines. Null when \
            the document has no MRZ.
            - "additionalFields": every other labeled value the document \
            prints that doesn't fit the schema above — vehicle classes, \
            restrictions, blood type, residence status, organ donor flag, \
            student-program code, etc. Use `{label, value}` pairs, label \
            verbatim. Empty array when nothing extra.

            Output a single JSON object in the shape specified.
            """,
            jsonHint: #"""
            {"documentType": "string or null", "documentNumber": "string or null", "givenName": "string or null", "familyName": "string or null", "fullName": "string or null", "dateOfBirth": "string or null", "sex": "string or null", "nationality": "string or null", "issuingAuthority": "string or null", "issueDate": "string or null", "expiryDate": "string or null", "address": "string or null", "mrz": "string or null", "additionalFields": [{"label": "string", "value": "string"}]}
            """#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        return clean(try await runner.run(task, images: [image]))
    }

    // MARK: - Raw model output + cleanup

    struct IDRaw: Codable, Sendable {
        let documentType: String?
        let documentNumber: String?
        let givenName: String?
        let familyName: String?
        let fullName: String?
        let dateOfBirth: String?
        let sex: String?
        let nationality: String?
        let issuingAuthority: String?
        let issueDate: String?
        let expiryDate: String?
        let address: String?
        let mrz: String?
        let additionalFields: [FieldRaw]?

        struct FieldRaw: Codable, Sendable {
            let label: String?
            let value: String?
        }
    }

    /// Trim strings, drop blank entries, snap document type to the known list
    /// when it matches. Internal so tests can pin the shape.
    static func clean(_ raw: IDRaw) -> IDDocumentData {
        let additional: [IDField] = (raw.additionalFields ?? []).compactMap { field in
            let label = (field.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else { return nil }
            return IDField(label: label, value: value)
        }
        return IDDocumentData(
            documentType: normalizeDocumentType(raw.documentType),
            documentNumber: raw.documentNumber.nilIfBlank,
            givenName: raw.givenName.nilIfBlank,
            familyName: raw.familyName.nilIfBlank,
            fullName: raw.fullName.nilIfBlank,
            dateOfBirth: raw.dateOfBirth.nilIfBlank,
            sex: raw.sex.nilIfBlank,
            nationality: raw.nationality.nilIfBlank,
            issuingAuthority: raw.issuingAuthority.nilIfBlank,
            issueDate: raw.issueDate.nilIfBlank,
            expiryDate: raw.expiryDate.nilIfBlank,
            address: raw.address.nilIfBlank,
            mrz: raw.mrz.nilIfBlank,
            additionalFields: additional
        )
    }

    /// Snap the model's free-text type to one of `knownDocumentTypes`
    /// case-insensitively. Anything we don't recognize survives as printed.
    static func normalizeDocumentType(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if let snapped = knownDocumentTypes.first(where: { $0.lowercased() == lower }) {
            return snapped
        }
        // Common synonyms.
        switch lower {
        case "driver license", "drivers license", "driving license", "dl",
             "運転免許証", "免許証":
            return "Driver's License"
        case "id card", "identity card", "個人番号カード", "マイナンバーカード", "在留カード":
            return "National ID"
        case "passport", "passeport", "パスポート", "旅券":
            return "Passport"
        default:
            return trimmed
        }
    }

    // MARK: - JSON export

    /// Stable JSON shape for AppIntents / Shortcuts hand-off. Optional fields
    /// are emitted as `null` (rather than omitted) so receiving Shortcuts can
    /// rely on key presence. UTF-8 encoded; the recipe never sees this value
    /// itself, so a downstream system can parse it however it likes.
    public static func json(_ data: IDDocumentData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let payload = JSONPayload(
            documentType: data.documentType,
            documentNumber: data.documentNumber,
            givenName: data.givenName,
            familyName: data.familyName,
            fullName: data.fullName,
            dateOfBirth: data.dateOfBirth,
            sex: data.sex,
            nationality: data.nationality,
            issuingAuthority: data.issuingAuthority,
            issueDate: data.issueDate,
            expiryDate: data.expiryDate,
            address: data.address,
            mrz: data.mrz,
            additionalFields: data.additionalFields
        )
        let bytes = try encoder.encode(payload)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Codable mirror of `IDDocumentData` so we can emit `null` for absent
    /// fields without writing a custom encoder on the public struct.
    private struct JSONPayload: Encodable {
        let documentType: String?
        let documentNumber: String?
        let givenName: String?
        let familyName: String?
        let fullName: String?
        let dateOfBirth: String?
        let sex: String?
        let nationality: String?
        let issuingAuthority: String?
        let issueDate: String?
        let expiryDate: String?
        let address: String?
        let mrz: String?
        let additionalFields: [IDField]

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(documentType, forKey: .documentType)
            try container.encode(documentNumber, forKey: .documentNumber)
            try container.encode(givenName, forKey: .givenName)
            try container.encode(familyName, forKey: .familyName)
            try container.encode(fullName, forKey: .fullName)
            try container.encode(dateOfBirth, forKey: .dateOfBirth)
            try container.encode(sex, forKey: .sex)
            try container.encode(nationality, forKey: .nationality)
            try container.encode(issuingAuthority, forKey: .issuingAuthority)
            try container.encode(issueDate, forKey: .issueDate)
            try container.encode(expiryDate, forKey: .expiryDate)
            try container.encode(address, forKey: .address)
            try container.encode(mrz, forKey: .mrz)
            try container.encode(additionalFields, forKey: .additionalFields)
        }

        enum CodingKeys: String, CodingKey {
            case documentType, documentNumber, givenName, familyName, fullName
            case dateOfBirth, sex, nationality, issuingAuthority, issueDate
            case expiryDate, address, mrz, additionalFields
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
