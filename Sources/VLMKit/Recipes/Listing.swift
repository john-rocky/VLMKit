import Foundation

/// A marketplace listing draft — what you'd post to Mercari, eBay, Yahoo
/// Auctions, Facebook Marketplace. Fixed schema of common listing fields, all
/// optional because the model honestly can't always read every aspect of an
/// item from photos alone (price is the obvious "rough estimate at best").
public struct ListingData: Sendable, Equatable {
    /// Short, scannable title — brand/model when visible, key descriptor otherwise.
    public let title: String?
    /// 2–4 sentence body. Friendly tone unless the intent string asks otherwise.
    public let description: String?
    /// Bullet-style key features (3–7 ideal). Buyer-relevant facts only.
    public let features: [String]
    /// One of `Listing.knownConditions` when recognizable; raw model text otherwise.
    public let condition: String?
    /// Free-text range ("¥3,000 - 5,000", "$20 - 30"). Nil when the model
    /// can't form an opinion — listing apps already prompt the seller to pick.
    public let suggestedPriceRange: String?
    /// 5–10 short search keywords, lowercased and de-duplicated.
    public let tags: [String]
    /// Single-sentence accessibility description of the primary image.
    public let altText: String?

    public init(
        title: String?,
        description: String?,
        features: [String],
        condition: String?,
        suggestedPriceRange: String?,
        tags: [String],
        altText: String?
    ) {
        self.title = title
        self.description = description
        self.features = features
        self.condition = condition
        self.suggestedPriceRange = suggestedPriceRange
        self.tags = tags
        self.altText = altText
    }
}

/// One VLM-proposed background style for a listing photo.
/// - `query` is the long, descriptive scene (8–14 words with lighting and
///   material) tuned for diffusion generators that thrive on detail.
/// - `keywords` is a short 2–4 word stock-photo search query tuned for
///   keyword APIs like Pexels that prefer terse input. Nil means the
///   orchestrator should fall back to `query`.
/// - `color` is a palette token from the curated set ("warm beige",
///   "cool gray", "deep navy", …) so the Solid-background mode can render
///   without the VLM having to commit to RGB.
///
/// All three come back as best-effort — the orchestrator can still fall
/// back to defaults.
public struct BackgroundStyleSuggestion: Sendable, Equatable, Codable {
    public let query: String
    public let keywords: String?
    public let color: String?

    public init(query: String, keywords: String? = nil, color: String? = nil) {
        self.query = query
        self.keywords = keywords
        self.color = color
    }
}

/// Marketplace-listing draft generator. Multi-image (one item, multiple angles)
/// + multi-turn (refine via natural-language instruction). Trades the schema-
/// driven extraction pattern of `Receipt`/`BusinessCard` for **generation** —
/// the VLM is writing copy, not transcribing what's printed.
public enum Listing {
    /// The condition buckets we ask the model to snap to. Aligned with how
    /// most marketplaces categorize. Free text that doesn't match falls
    /// through verbatim.
    public static let knownConditions: [String] = [
        "New",
        "Like New",
        "Used - Good",
        "Used - Fair",
        "Used - Heavy Wear",
        "For Parts",
    ]

    /// Listing draft cap: more than this and the title bar / preview cards get
    /// noisy. Internal to the recipe — callers don't need to think about it.
    static let maxFeatures = 7
    static let maxTags = 10

    /// First pass: read the photos (one item, multiple angles), write a draft
    /// listing. `intent` is an optional natural-language hint about audience,
    /// tone, or marketplace (e.g. "Mercari, casual tone, target buyers in
    /// their 20s"). Returns nil-friendly fields — anything the model isn't
    /// confident about is left out instead of hallucinated.
    public static func generate(
        on images: [VLMImage],
        intent: String? = nil,
        runner: VLMRunner
    ) async throws -> ListingData {
        let intentBlock = intent
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .map { "\n\nSeller intent: \($0)" } ?? ""
        let task = VLMTask<ListingRaw>(
            instruction: """
            You are writing a marketplace listing (Mercari, eBay, Yahoo \
            Auctions, Facebook Marketplace, etc.) for the single item shown \
            across these photos.\(intentBlock)

            Generate the fields below. Use null for any field you cannot \
            write with confidence — do NOT invent facts that aren't visible \
            (size labels, brand, year, materials).

            Rules:
            - "title": short, scannable. Lead with the most identifiable thing \
            visible (brand, model, type). Avoid hype words ("amazing!", "rare!") \
            unless the photos actually show that.
            - "description": 2–4 sentences. Friendly, factual. No price talk in \
            here (price has its own field).
            - "features": 3–\(maxFeatures) bullet points. Each ≤80 chars. Things \
            a buyer would want to know.
            - "condition": one of \(knownConditions.joined(separator: ", ")). \
            Pick the closest match based on visible wear/damage. Null only when \
            truly ambiguous.
            - "suggestedPriceRange": a rough range as a string ("¥3,000 - \
            5,000", "$20 - 30"). Use the currency that fits the seller intent \
            if given, otherwise the obvious one for the item. Null when you \
            genuinely cannot estimate — leaving it null is better than guessing.
            - "tags": 5–\(maxTags) short keywords (single words or short \
            phrases) buyers might search. Lowercase.
            - "altText": one sentence describing the item visually for \
            accessibility.

            Output a single JSON object in the shape specified.
            """,
            jsonHint: #"""
            {"title": "string or null", "description": "string or null", "features": ["string"], "condition": "string or null", "suggestedPriceRange": "string or null", "tags": ["string"], "altText": "string or null"}
            """#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.4)
        )
        return clean(try await runner.run(task, images: images))
    }

    /// Refinement pass: same item photos, plus the previous draft, plus the
    /// user's natural-language instruction ("more casual", "translate to
    /// English", "emphasize the rare feature"). Returns a new draft that
    /// keeps what works and changes what the user asked for.
    public static func refine(
        _ previous: ListingData,
        on images: [VLMImage],
        instruction: String,
        runner: VLMRunner
    ) async throws -> ListingData {
        let previousJSON = (try? prettyPrintedJSON(previous)) ?? "(empty draft)"
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = VLMTask<ListingRaw>(
            instruction: """
            You previously generated a marketplace listing for the item shown \
            in these photos. The seller wants a revision.

            Previous draft:
            \(previousJSON)

            Seller's revision instruction:
            "\(trimmed)"

            Return an updated listing in the SAME JSON shape. Keep fields that \
            already work; change only what the instruction asks for (or what \
            its tone implies). Use null for any field you cannot write with \
            confidence — don't invent facts.
            """,
            jsonHint: #"""
            {"title": "string or null", "description": "string or null", "features": ["string"], "condition": "string or null", "suggestedPriceRange": "string or null", "tags": ["string"], "altText": "string or null"}
            """#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.4)
        )
        return clean(try await runner.run(task, images: images))
    }

    /// Curated color palette the VLM is asked to snap to when suggesting
    /// backgrounds for the Solid-background mode. Keep this in sync with the
    /// app-side `SolidGradientBackground.palette`; if the VLM proposes a token
    /// that isn't here, the Solid mode will fall back to "off white".
    public static let knownBackgroundColors: [String] = [
        "white", "off white", "warm beige", "cream",
        "cool gray", "warm gray", "soft pink", "sage green",
        "deep navy", "charcoal", "wood brown",
    ]

    /// Ask the VLM to propose 3 background styles for a marketplace hero
    /// photo of the item across `images`. One VLM call; the model considers
    /// the item type, color, and likely buyer aesthetic. Returns up to
    /// `count` suggestions — the prompt asks for 3, but the cleaner trims
    /// blanks so callers may get fewer.
    public static func suggestBackgroundStyles(
        on images: [VLMImage],
        runner: VLMRunner,
        count: Int = 3
    ) async throws -> [BackgroundStyleSuggestion] {
        let task = VLMTask<BackgroundSuggestionsRaw>(
            instruction: """
            Look at the item shown across these photos. First identify what it \
            actually is — category, material, color, era, price tier, who the \
            likely buyer is, what context a buyer would imagine using it in. \
            Then propose \(count) distinct background scenes that suit THIS \
            specific item in a marketplace hero shot.

            Tailor to the item AND vary the category. The \(count) scenes must \
            come from THREE DIFFERENT CATEGORIES (do not return three desks, \
            three kitchens, three studios):
              · INDOOR domestic — a kitchen, dining table, living room shelf, \
                bedside, hallway with character
              · OUTDOOR or semi-outdoor — a sunlit balcony, garden patio, \
                park bench, beach mat, café terrace
              · CHARACTER / VINTAGE — a workshop, writer's study, atelier, \
                vinyl-record corner, plant-filled nook, retro diner

            Pick PLACES the buyer can imagine the item in, mixed across the \
            three categories above. Do not fall back on generic "white \
            studio / wood plank / linen drape" texture defaults.

            For each background, picture a WIDE environmental shot — a room, \
            interior, or outdoor setting where this item naturally belongs. \
            NOT a close-up of a single surface (a marble slab, a wood plank, \
            a fabric drape). The viewer should be able to recognize the place \
            ("oh, that's a vintage study / a modern kitchen / a sunlit \
            patio"), not just a texture. Include depth: foreground surface + \
            background context (a wall, shelves, a window). Leave the \
            foreground center clear so the product can sit there.

            For each background:
            - "query": an 8–14 word description of the WIDE scene for an \
            image-generation model. Name the place type (room, interior, \
            patio…), one or two characterful details (vintage typewriter on \
            a shelf, hanging plants, brass fixtures…), and the lighting. \
            Examples: "vintage writer's study with leather books on shelves \
            and warm desk lamp light", "minimalist scandinavian kitchen with \
            white tile wall and morning window light", "industrial loft \
            workshop with brick wall and pendant lights overhead". Keep the \
            foreground center an empty surface where the product will sit. \
            Do not mention the product itself, people, faces, text, or logos.
            - "keywords": 2–4 word stock-photo search query naming the PLACE, \
            not the texture. Pexels prefers terse input. Use "interior", \
            "room", "kitchen", "cafe", "garden", "patio", "workshop", \
            "library" so results come back as wide environment photos. \
            Examples: "scandinavian kitchen interior", "garden patio table", \
            "vintage workshop interior". \
            BANNED words (they return bland white close-ups on Pexels): \
            "minimalist", "clean", "modern", "white", "studio", "desk", \
            "office", "nook", "background", "texture", "backdrop". \
            Also avoid bare material words ("wood", "marble", "linen") — \
            those return close-up textures.
            - "color": one of \(knownBackgroundColors.joined(separator: ", ")) \
            — the dominant tone of that scene. Pick the closest. Use null \
            only when no tone fits.

            The \(count) backgrounds must be visually distinct from each \
            other (different surfaces, settings, or moods — not three shades \
            of the same idea).

            Output one JSON object in the shape specified.
            """,
            jsonHint: #"""
            {"styles": [{"query": "string", "keywords": "string or null", "color": "string or null"}]}
            """#,
            options: GenerationOptions(maxTokens: 512, temperature: 0.7)
        )
        let raw = try await runner.run(task, images: images)
        return cleanBackgroundSuggestions(raw.styles, cap: count)
    }

    struct BackgroundSuggestionsRaw: Codable, Sendable {
        let styles: [SuggestionRaw]

        struct SuggestionRaw: Codable, Sendable {
            let query: String?
            let keywords: String?
            let color: String?
        }
    }

    /// Trim each suggestion, drop entries with no query, snap color to the
    /// known palette when it matches, cap to `cap`. `keywords` is preserved
    /// verbatim (only trimmed) — the consumer treats it as a search hint and
    /// already falls back to `query` when nil. Internal so tests can pin the
    /// shape later (skipped for now; this is a thin transform).
    static func cleanBackgroundSuggestions(
        _ raw: [BackgroundSuggestionsRaw.SuggestionRaw],
        cap: Int
    ) -> [BackgroundStyleSuggestion] {
        var out: [BackgroundStyleSuggestion] = []
        for entry in raw {
            let query = (entry.query ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            let keywords = entry.keywords
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            let color = entry.color
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
                .flatMap { raw -> String? in
                    let lower = raw.lowercased()
                    return knownBackgroundColors.first { $0.lowercased() == lower }
                }
            out.append(BackgroundStyleSuggestion(query: query, keywords: keywords, color: color))
            if out.count >= cap { break }
        }
        return out
    }

    // MARK: - Internal

    struct ListingRaw: Codable, Sendable {
        let title: String?
        let description: String?
        let features: [String]?
        let condition: String?
        let suggestedPriceRange: String?
        let tags: [String]?
        let altText: String?
    }

    /// Trim every string, drop blank list entries, snap the condition to the
    /// known bucket when it matches, lowercase + de-duplicate tags, cap
    /// features and tags to their max. Internal so tests can pin the shape.
    static func clean(_ raw: ListingRaw) -> ListingData {
        let features = trimAndTake(raw.features ?? [], cap: maxFeatures)
        let tags = uniqueLowercased(raw.tags ?? [], cap: maxTags)
        return ListingData(
            title: raw.title.nilIfBlank,
            description: raw.description.nilIfBlank,
            features: features,
            condition: raw.condition.flatMap(normalizeCondition),
            suggestedPriceRange: raw.suggestedPriceRange.nilIfBlank,
            tags: tags,
            altText: raw.altText.nilIfBlank
        )
    }

    /// Snap the model's free-text condition to one of `knownConditions`
    /// case-insensitively. Anything we don't recognize survives as printed —
    /// the model might pick a new sensible bucket name on a future tune.
    static func normalizeCondition(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let snapped = knownConditions.first(where: { $0.lowercased() == lower }) {
            return snapped
        }
        // Common synonyms.
        switch lower {
        case "mint", "brand new": return "New"
        case "excellent", "near new": return "Like New"
        case "good", "very good": return "Used - Good"
        case "fair", "acceptable": return "Used - Fair"
        case "heavy wear", "worn", "damaged": return "Used - Heavy Wear"
        case "parts", "for parts only", "broken": return "For Parts"
        default: return trimmed
        }
    }

    /// Trim each string, drop empties, cap at `cap`. Order from the model is
    /// preserved — the VLM tends to list features in priority order.
    private static func trimAndTake(_ raw: [String], cap: Int) -> [String] {
        var out: [String] = []
        for entry in raw {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append(trimmed)
            if out.count >= cap { break }
        }
        return out
    }

    /// Lowercase, trim, dedupe (preserving first occurrence), cap. Tags are
    /// case-insensitive search keys, so a Tag set of {"vintage", "Vintage",
    /// "VINTAGE"} should collapse.
    private static func uniqueLowercased(_ raw: [String], cap: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            let normalized = entry
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            out.append(normalized)
            if out.count >= cap { break }
        }
        return out
    }

    /// Pretty-print `ListingData` as JSON for embedding in the refine prompt.
    /// Sorted keys so the model sees a stable shape across turns.
    private static func prettyPrintedJSON(_ data: ListingData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let payload = JSONPayload(
            title: data.title,
            description: data.description,
            features: data.features,
            condition: data.condition,
            suggestedPriceRange: data.suggestedPriceRange,
            tags: data.tags,
            altText: data.altText
        )
        let bytes = try encoder.encode(payload)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Public JSON serialization used by the AppIntent return value.
    public static func json(_ data: ListingData) throws -> String {
        try prettyPrintedJSON(data)
    }

    private struct JSONPayload: Encodable {
        let title: String?
        let description: String?
        let features: [String]
        let condition: String?
        let suggestedPriceRange: String?
        let tags: [String]
        let altText: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(description, forKey: .description)
            try container.encode(features, forKey: .features)
            try container.encode(condition, forKey: .condition)
            try container.encode(suggestedPriceRange, forKey: .suggestedPriceRange)
            try container.encode(tags, forKey: .tags)
            try container.encode(altText, forKey: .altText)
        }

        enum CodingKeys: String, CodingKey {
            case title, description, features, condition
            case suggestedPriceRange, tags, altText
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
