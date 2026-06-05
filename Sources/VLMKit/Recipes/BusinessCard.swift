import Foundation

/// Structured data read off a business card. Fixed schema, optional fields —
/// cards vary wildly, so a missing piece is more honest than a hallucinated one.
public struct BusinessCardData: Sendable, Equatable {
    /// Given (personal) name. Latin: "Taro" / "Jane".
    public let givenName: String?
    /// Family (sur)name. Latin: "Yamada" / "Doe".
    public let familyName: String?
    /// Raw printed full name. Fallback when the model can't split into given/family.
    public let fullName: String?
    /// Japanese cards often print a phonetic guide ("ふりがな" — e.g. "ヤマダ タロウ").
    /// Captured so Contacts' search-by-pronunciation works; nil otherwise.
    public let phoneticName: String?
    public let company: String?
    public let department: String?
    public let title: String?
    public let phones: [BusinessCardPhone]
    public let emails: [String]
    public let urls: [String]
    /// Single-string postal address as printed; not parsed into CNPostalAddress
    /// components because postal formats vary too much across locales.
    public let address: String?
    public let socials: [BusinessCardSocial]

    public init(
        givenName: String?,
        familyName: String?,
        fullName: String?,
        phoneticName: String?,
        company: String?,
        department: String?,
        title: String?,
        phones: [BusinessCardPhone],
        emails: [String],
        urls: [String],
        address: String?,
        socials: [BusinessCardSocial]
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.fullName = fullName
        self.phoneticName = phoneticName
        self.company = company
        self.department = department
        self.title = title
        self.phones = phones
        self.emails = emails
        self.urls = urls
        self.address = address
        self.socials = socials
    }

    /// Convenience: best display name in order of preference: split → full → either part.
    public var displayName: String {
        if let given = givenName, let family = familyName {
            // Japanese cards typically print family first, then given. Western
            // cards print given first. Default to given-first; callers that
            // need locale-aware ordering can build their own string from the
            // parts.
            return "\(given) \(family)"
        }
        return fullName ?? givenName ?? familyName ?? ""
    }
}

public struct BusinessCardPhone: Sendable, Equatable {
    /// Free-text label as printed ("Mobile", "Office", "携帯", "Fax") OR one of
    /// `BusinessCard.knownPhoneKinds` after normalization. Nil = unknown.
    public let kind: String?
    public let number: String

    public init(kind: String?, number: String) {
        self.kind = kind
        self.number = number
    }
}

public struct BusinessCardSocial: Sendable, Equatable {
    /// Platform name as printed: "LinkedIn", "X", "Twitter", "GitHub", "Instagram".
    public let platform: String
    /// Handle or URL exactly as printed.
    public let handle: String

    public init(platform: String, handle: String) {
        self.platform = platform
        self.handle = handle
    }
}

/// Business-card extraction — one VLM call per card against a fixed schema. The
/// extracted data drops cleanly into Apple's `Contacts` framework (the app
/// wraps it in a `CNMutableContact` and presents a preview before saving), and
/// the same schema serializes to vCard 3.0 for AppIntents / Shortcuts return
/// values.
public enum BusinessCard {
    /// The phone-kind buckets we ask the model to snap to. Maps cleanly to
    /// Apple Contacts' `CNLabel*` constants in the app layer. Free-text from
    /// the model that doesn't match is preserved verbatim in `phones[].kind`.
    public static let knownPhoneKinds: [String] = [
        "Mobile", "Office", "Home", "Fax", "Main", "Other",
    ]

    /// Extract structured contact data from a single business-card image.
    public static func extract(
        on image: VLMImage,
        runner: VLMRunner
    ) async throws -> BusinessCardData {
        let task = VLMTask<BusinessCardRaw>(
            instruction: """
            You are reading a business card. Extract the contact fields below \
            from what is printed. Use null for any field you cannot read with \
            confidence — do NOT guess.

            Rules:
            - "givenName" / "familyName": split the printed name into given \
            (personal) and family (sur) parts. If the order is unclear or you \
            cannot split, leave both null and put the full name in "fullName".
            - "fullName": the printed name verbatim, only when you cannot \
            confidently split it. Otherwise null.
            - "phoneticName": a phonetic / pronunciation guide for the name \
            (e.g. Japanese ふりがな / katakana reading printed alongside kanji). \
            Null when the card has none.
            - "company": organization name as printed.
            - "department": team / division as printed (e.g. "Engineering", \
            "営業部"). Null when only company is shown.
            - "title": job title or role as printed.
            - "phones": each printed phone number with a "kind" label. Prefer \
            one of \(knownPhoneKinds.joined(separator: ", ")); use the printed \
            label as-is if it doesn't fit. Keep the number in the format printed \
            (Apple Contacts normalizes formatting).
            - "emails": every printed email address.
            - "urls": every printed website / company URL. Skip social handles \
            (they belong in "socials").
            - "address": the postal address as a single string, joined with \
            commas if printed on multiple lines. Null when no address is shown.
            - "socials": each social-media link with platform ("LinkedIn", \
            "X", "Twitter", "Instagram", "GitHub", …) and the handle/URL as \
            printed.

            Output a single JSON object in the shape specified.
            """,
            jsonHint: #"""
            {"givenName": "string or null", "familyName": "string or null", "fullName": "string or null", "phoneticName": "string or null", "company": "string or null", "department": "string or null", "title": "string or null", "phones": [{"kind": "string or null", "number": "string"}], "emails": ["string"], "urls": ["string"], "address": "string or null", "socials": [{"platform": "string", "handle": "string"}]}
            """#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        return clean(try await runner.run(task, images: [image]))
    }

    // MARK: - Raw model output + cleanup

    struct BusinessCardRaw: Codable, Sendable {
        let givenName: String?
        let familyName: String?
        let fullName: String?
        let phoneticName: String?
        let company: String?
        let department: String?
        let title: String?
        let phones: [PhoneRaw]?
        let emails: [String]?
        let urls: [String]?
        let address: String?
        let socials: [SocialRaw]?

        struct PhoneRaw: Codable, Sendable {
            let kind: String?
            let number: String?
        }

        struct SocialRaw: Codable, Sendable {
            let platform: String?
            let handle: String?
        }
    }

    /// Trim strings, drop blank entries, and snap phone-kind labels to the
    /// known buckets when they match. Internal so tests can pin the shape.
    static func clean(_ raw: BusinessCardRaw) -> BusinessCardData {
        let phones: [BusinessCardPhone] = (raw.phones ?? []).compactMap { phone in
            let number = (phone.number ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !number.isEmpty else { return nil }
            return BusinessCardPhone(
                kind: normalizePhoneKind(phone.kind),
                number: number
            )
        }
        let emails = (raw.emails ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let urls = (raw.urls ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let socials: [BusinessCardSocial] = (raw.socials ?? []).compactMap { social in
            let platform = (social.platform ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let handle = (social.handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !platform.isEmpty, !handle.isEmpty else { return nil }
            return BusinessCardSocial(platform: platform, handle: handle)
        }
        return BusinessCardData(
            givenName: raw.givenName.nilIfBlank,
            familyName: raw.familyName.nilIfBlank,
            fullName: raw.fullName.nilIfBlank,
            phoneticName: raw.phoneticName.nilIfBlank,
            company: raw.company.nilIfBlank,
            department: raw.department.nilIfBlank,
            title: raw.title.nilIfBlank,
            phones: phones,
            emails: emails,
            urls: urls,
            address: raw.address.nilIfBlank,
            socials: socials
        )
    }

    /// Snap a free-text phone kind to one of `knownPhoneKinds` case-insensitively.
    /// Falls back to the printed label trimmed (or nil if blank) so non-English
    /// labels like "携帯" survive instead of being silently dropped.
    static func normalizePhoneKind(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if let snapped = knownPhoneKinds.first(where: { $0.lowercased() == lower }) {
            return snapped
        }
        // Common synonyms — collapse to the canonical bucket where it's clearly
        // the same kind ("Cell" / "携帯" → "Mobile", "Work" → "Office").
        switch lower {
        case "cell", "cell phone", "携帯", "mobile phone": return "Mobile"
        case "work", "tel", "phone", "電話", "代表": return "Office"
        default: return trimmed  // preserve unknown label as printed
        }
    }

    // MARK: - vCard export

    /// vCard 3.0 representation. Stable, RFC-6350-ish — enough for AppIntents
    /// to hand off to Mail, Messages, or any system that ingests `.vcf`.
    public static func vCard(_ data: BusinessCardData) -> String {
        var lines: [String] = ["BEGIN:VCARD", "VERSION:3.0"]
        // N: family;given;additional;prefix;suffix  (3.0 structured name).
        let family = data.familyName ?? ""
        let given = data.givenName ?? ""
        if !family.isEmpty || !given.isEmpty {
            lines.append("N:\(vCardEscape(family));\(vCardEscape(given));;;")
        }
        let display = data.displayName
        if !display.isEmpty {
            lines.append("FN:\(vCardEscape(display))")
        } else if let full = data.fullName {
            lines.append("FN:\(vCardEscape(full))")
        }
        if let company = data.company {
            let department = data.department.map { ";\(vCardEscape($0))" } ?? ""
            lines.append("ORG:\(vCardEscape(company))\(department)")
        }
        if let title = data.title {
            lines.append("TITLE:\(vCardEscape(title))")
        }
        for phone in data.phones {
            let typeParam = vCardPhoneType(phone.kind)
            lines.append("TEL\(typeParam):\(phone.number)")
        }
        for email in data.emails {
            lines.append("EMAIL;TYPE=WORK:\(email)")
        }
        for url in data.urls {
            lines.append("URL:\(url)")
        }
        if let address = data.address {
            // vCard 3.0 ADR is structured; we only have a single string, so use
            // the LABEL field (free-text postal address) which most clients
            // also render. ADR is also emitted with the value in the locality
            // slot so contacts that ignore LABEL still see something.
            lines.append("ADR:;;\(vCardEscape(address));;;;")
            lines.append("LABEL:\(vCardEscape(address))")
        }
        for social in data.socials {
            // Non-standard X- prefixed property — used by macOS/iOS for social
            // platforms when no native field maps. Most clients display it.
            lines.append("X-SOCIALPROFILE;TYPE=\(vCardEscape(social.platform)):\(social.handle)")
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\r\n")
    }

    /// vCard requires escaping of `,` `;` `\` and newlines inside text values.
    private static func vCardEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Map our phone-kind label to a vCard TEL TYPE parameter.
    private static func vCardPhoneType(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "mobile": ";TYPE=CELL,VOICE"
        case "office": ";TYPE=WORK,VOICE"
        case "home": ";TYPE=HOME,VOICE"
        case "fax": ";TYPE=WORK,FAX"
        case "main": ";TYPE=WORK,VOICE,PREF"
        default: ";TYPE=VOICE"
        }
    }
}

private extension Optional where Wrapped == String {
    /// Trim whitespace and collapse empty/whitespace-only strings to `nil`.
    /// Local copy so this recipe doesn't reach into another recipe's private
    /// helpers — keeps each file self-contained.
    var nilIfBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}
