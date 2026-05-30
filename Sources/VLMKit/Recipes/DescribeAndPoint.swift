import Foundation

/// One concrete object the caption mentions. `phrase` is copied verbatim from the
/// caption (drives the in-text highlight); `query` is a short generic noun handed
/// to the detector; `range` is where `phrase` sits inside `caption`.
public struct DescribedObject: Sendable {
    public let phrase: String
    public let query: String
    public let range: Range<String.Index>
}

/// A caption plus the concrete objects it names, ordered by their position in the text.
public struct Description: Sendable {
    public let caption: String
    public let objects: [DescribedObject]
}

/// "Describe & Point" — grounded narration. The VLM writes a short, natural
/// description of the image and names the concrete objects it mentions; a separate
/// on-device detector (YOLOE, app-side) later boxes each one on the photo, one at a
/// time, in the order it appears in the sentence.
///
/// The split is deliberate: the VLM does *language only* — a caption plus, for each
/// named object, the verbatim caption span (`phrase`, for the in-text highlight) and
/// a short detector noun (`query`). It returns **no coordinates**; the VLM's own
/// `bbox_2d` is too unreliable to point with. Localization is the caller's job (an
/// Apple/open-vocab detector says *where*), so this core recipe stays detector-
/// agnostic — it returns the caption and the ordered, in-text-located objects, and
/// nothing more.
public enum DescribeAndPoint {
    /// Decoded straight from the model: a caption and `{phrase, query}` per object,
    /// with no coordinates and no located range yet.
    struct DescribedObjectRaw: Codable, Sendable {
        let phrase: String
        let query: String
    }
    struct DescriptionRaw: Codable, Sendable {
        let caption: String
        let objects: [DescribedObjectRaw]
    }

    /// One VLM call → a caption + the concrete objects it names. Each object's
    /// `phrase` is located in the caption, the objects are sorted into caption order
    /// (the model's array order is not trusted), and the list is capped to
    /// `maxObjects`. Objects whose `phrase` cannot be found verbatim are dropped.
    public static func run(
        on image: VLMImage,
        runner: VLMRunner,
        maxObjects: Int = 8
    ) async throws -> Description {
        let task = VLMTask<DescriptionRaw>(
            instruction: """
            You are describing a photo for a reader who will then see each object \
            you mention highlighted on the image, one at a time.

            First write a SHORT, natural description — one to three plain sentences, \
            the kind of caption a person would write. Then list the concrete, \
            physical objects you named, in the order they appear in your sentences.

            For each object give:
            - "phrase": the words for that object copied VERBATIM from your caption \
            (character for character, so it can be found inside the caption). Keep \
            it short — the noun and any words attached to it, e.g. "a red mug".
            - "query": a short generic name for that same object for an object \
            detector — a concrete noun, lowercase, no article, one or two words, \
            e.g. "mug", "wooden table", "dog".

            Rules:
            - Only objects that are concrete, physically visible, and could be \
            outlined with a box (a cup, a chair, a person, a car).
            - Do NOT list the sky, ground, floor, walls, background, lighting, \
            weather, colors, or anything that cannot be boxed.
            - List at most \(maxObjects) objects — the most prominent ones.
            - Every "phrase" MUST appear verbatim in the caption.
            - Do NOT include any coordinates, boxes, or positions — only words.
            """,
            jsonHint: #"{"caption": "a short natural description", "objects": [{"phrase": "exact words from caption", "query": "short detector noun"}]}"#,
            options: GenerationOptions(maxTokens: 512, temperature: 0.2)
        )
        let raw = try await runner.run(task, images: [image])
        let caption = raw.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return Description(caption: caption, objects: locate(raw.objects, in: caption, maxObjects: maxObjects))
    }

    /// Locate each `phrase` in `caption`, sort by position, and cap to `maxObjects`.
    /// Duplicate identical phrases are consumed left→right (so "a cat … another cat"
    /// maps to the two occurrences); distinct phrases are each searched from the
    /// start, so the model listing them out of order does not break the mapping.
    /// A phrase that cannot be found verbatim is dropped.
    static func locate(_ raw: [DescribedObjectRaw], in caption: String, maxObjects: Int) -> [DescribedObject] {
        var nextStart: [String: String.Index] = [:]   // per identical phrase: where to resume
        var located: [DescribedObject] = []
        for object in raw {
            let phrase = object.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }
            let key = phrase.lowercased()
            let start = nextStart[key] ?? caption.startIndex
            guard let range = caption.range(of: phrase, options: .caseInsensitive, range: start..<caption.endIndex) else { continue }
            nextStart[key] = range.upperBound
            located.append(DescribedObject(
                phrase: phrase,
                query: object.query.trimmingCharacters(in: .whitespacesAndNewlines),
                range: range
            ))
        }
        located.sort { $0.range.lowerBound < $1.range.lowerBound }
        return Array(located.prefix(maxObjects))
    }
}
