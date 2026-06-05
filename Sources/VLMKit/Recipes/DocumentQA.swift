import CoreGraphics
import Foundation

/// One labeled value the VLM read off a document — a key (the printed field name)
/// and its printed value, both copied verbatim from the page. For multi-page
/// documents, `page` is the 0-indexed page the field was read from; for single-page
/// it stays 0. The page is set by the recipe after decoding the model's JSON, so the
/// VLM's response shape stays the simpler `{label, value}` (page is not asked-for or
/// trusted from the model).
public struct DocumentField: Sendable, Codable, Equatable {
    public let label: String
    public let value: String
    public let page: Int

    enum CodingKeys: String, CodingKey { case label, value }

    public init(label: String, value: String, page: Int = 0) {
        self.label = label
        self.value = value
        self.page = page
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try container.decode(String.self, forKey: .label)
        self.value = try container.decode(String.self, forKey: .value)
        self.page = 0  // page is assigned by the recipe after decode.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(value, forKey: .value)
    }
}

/// One OCR observation — a piece of recognized text and where it sits on the page.
/// `box` is image-normalized (0...1, top-left origin), matching VLMKit's convention.
/// `page` is 0-indexed for multi-page documents (0 for single-page). Recipes accept
/// this generic type so they stay OCR-engine-agnostic; the caller runs the actual
/// text recognition (Vision, Tesseract, …) and hands the observations in.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public let page: Int

    public init(text: String, box: CGRect, page: Int = 0) {
        self.text = text
        self.box = box
        self.page = page
    }
}

/// The structured key/value reading of a document.
public struct DocumentExtraction: Sendable {
    public let fields: [DocumentField]
}

/// One free-form question's answer, with optional supporting text from the document.
public struct DocumentAnswer: Sendable {
    public let answer: String
    /// Verbatim text from the document that supports the answer, or nil if the VLM
    /// could not point to a specific span (or chose not to). Useful for grounding —
    /// a later OCR pass can box this string on the photo to show *where* the value
    /// was read.
    public let evidence: String?
    /// 0-indexed page the evidence was found on, or nil if the model couldn't (or
    /// didn't need to) pinpoint a page. Always nil for single-page documents — the
    /// caller already knows the page in that case.
    public let page: Int?

    public init(answer: String, evidence: String?, page: Int? = nil) {
        self.answer = answer
        self.evidence = evidence
        self.page = page
    }
}

/// Document Q&A — read a document's labeled fields, then answer free-form
/// questions about it. Works on any printed page: a machine plate, an invoice, a
/// business card, a label, a form.
///
/// Two calls, two purposes:
/// - `extract` lists every labeled value the VLM can read off the page (model
///   number, date, totals, …) in one structured call. Stable; runs once when the
///   user captures an image.
/// - `ask` answers a specific natural-language question (e.g. "What is the frame
///   number?") and, when possible, cites the verbatim text it relied on. Ad-hoc;
///   re-runs each time the user submits a question.
///
/// They are split so callers decide the cadence — and so a Q&A pass can reuse a
/// cached extraction instead of re-reading the whole page.
public enum DocumentQA {
    /// Decoded straight from the model; the public `DocumentExtraction` wraps the
    /// cleaned list.
    struct ExtractionRaw: Codable, Sendable {
        let fields: [DocumentField]
    }

    /// Read every labeled key/value pair visible on a single-page document.
    /// Convenience wrapper around the multi-page form.
    public static func extract(
        on image: VLMImage,
        runner: VLMRunner,
        maxFields: Int = 16
    ) async throws -> DocumentExtraction {
        try await extract(on: [image], runner: runner, maxFieldsPerPage: maxFields)
    }

    /// Read every labeled key/value pair visible across the pages of a document.
    /// Each page is processed independently (one VLM call per page, sequential so
    /// the actor-serialized backend isn't fighting itself) and the returned fields
    /// are tagged with their 0-indexed page so the caller can group / display by page.
    /// - `maxFieldsPerPage`: upper bound on returned pairs per page (default 16) —
    ///   keeps each call within the token budget on busy pages.
    public static func extract(
        on pages: [VLMImage],
        runner: VLMRunner,
        maxFieldsPerPage: Int = 16
    ) async throws -> DocumentExtraction {
        var merged: [DocumentField] = []
        for (pageIndex, image) in pages.enumerated() {
            let task = VLMTask<ExtractionRaw>(
                instruction: """
                You are reading a document — a form, machine plate, label, invoice, \
                receipt, business card, or any printed page. List every labeled value \
                you can read off it as label/value pairs.

                For each field:
                - "label": the printed name of the field, copied verbatim — short, \
                e.g. "Model Number", "Date", "Total".
                - "value": what is printed against that label, copied verbatim, in the \
                language and casing it is written in. Numbers, codes, and dates stay \
                as printed.

                Rules:
                - Only include fields you can actually read; do NOT invent values, \
                and do NOT fill in fields that are blank or illegible.
                - Skip running prose, legal fine print, and full sentences — \
                label/value pairs only.
                - Return at most \(maxFieldsPerPage) fields — the most prominent ones if \
                the page has more.
                - Output one JSON object in the shape specified.
                """,
                jsonHint: #"{"fields": [{"label": "printed field name", "value": "printed value"}]}"#,
                options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
            )
            let raw = try await runner.run(task, images: [image])
            let cleaned = clean(raw.fields, maxFields: maxFieldsPerPage)
            merged.append(contentsOf: cleaned.map {
                DocumentField(label: $0.label, value: $0.value, page: pageIndex)
            })
        }
        return DocumentExtraction(fields: merged)
    }

    /// Trim, drop blank-label / blank-value pairs (the model occasionally pads with
    /// empties), and cap to the requested limit. Order from the model is preserved
    /// — the VLM tends to list fields in reading order, which matches the page.
    static func clean(_ raw: [DocumentField], maxFields: Int) -> [DocumentField] {
        var cleaned: [DocumentField] = []
        for field in raw {
            let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else { continue }
            cleaned.append(DocumentField(label: label, value: value))
            if cleaned.count >= maxFields { break }
        }
        return cleaned
    }

    struct AnswerRaw: Codable, Sendable {
        let answer: String
        let evidence: String?
        /// 1-indexed page the model cites the evidence from (matches the prompt's
        /// `Page 1`, `Page 2`, … labels). Null / 0 / out-of-range means "not
        /// pinpointed"; `cleanAnswer` collapses those to nil. Optional with a
        /// nil default so single-page tests can build an `AnswerRaw` without it.
        let page: Int?

        init(answer: String, evidence: String?, page: Int? = nil) {
            self.answer = answer
            self.evidence = evidence
            self.page = page
        }
    }

    /// Single-page convenience for `ask` — wraps the multi-page form. The returned
    /// answer's `page` is always nil (only one page in play, so there's nothing to
    /// disambiguate).
    public static func ask(
        _ question: String,
        on image: VLMImage,
        runner: VLMRunner,
        onPartialAnswer: (@Sendable (String) -> Void)? = nil
    ) async throws -> DocumentAnswer {
        try await ask(question, on: [image], runner: runner, onPartialAnswer: onPartialAnswer)
    }

    /// Answer a free-form natural-language question about a (possibly multi-page)
    /// document, citing the supporting text and the page it came from. All pages
    /// are passed to the model in one call so it can reason across them; the model
    /// is told the page order in the prompt and asked to return a 1-indexed page
    /// number for the cited evidence (converted to 0-indexed in the returned
    /// `DocumentAnswer.page`).
    ///
    /// Pass `onPartialAnswer` to stream the `answer` field character-by-character
    /// as the model generates it — useful for a live typewriter UI. The callback
    /// receives the answer-so-far each time it grows; the function still returns
    /// the final `DocumentAnswer` (with `evidence` and `page`) once generation
    /// completes. Streaming skips the JSON-parse retry the single-shot path uses;
    /// on parse failure it falls back to the partial answer with no evidence/page.
    public static func ask(
        _ question: String,
        on pages: [VLMImage],
        runner: VLMRunner,
        onPartialAnswer: (@Sendable (String) -> Void)? = nil
    ) async throws -> DocumentAnswer {
        let pageCount = pages.count
        let multiPage = pageCount > 1
        let pageInstruction = multiPage
            ? """
              You are looking at \(pageCount) pages of one document, given in order as \
              Page 1, Page 2, …, Page \(pageCount).
              """
            : "You are looking at a single-page document."
        let pageField = multiPage
            ? """
              - "page": the 1-indexed page number the evidence appears on (1…\(pageCount)). \
              Use 0 if you cannot point to a single page.
              """
            : ""
        let pageHint = multiPage ? #", "page": 1"# : ""
        let task = VLMTask<AnswerRaw>(
            instruction: """
            \(pageInstruction)

            You are answering a question about it — a form, machine plate, label, \
            invoice, receipt, business card, contract, manual, or any printed page.

            Question: \(question)

            Answer based ONLY on what is printed on the page(s).

            - "answer": a short, direct answer to the question, in the same \
            language as the question. If the document does not contain the \
            information, answer "Not stated".
            - "evidence": the verbatim phrase from the document that supports the \
            answer — a single short span, typically the label or the value. Use \
            an empty string if you cannot point to a specific span.
            \(pageField)
            """,
            jsonHint: #"{"answer": "short answer", "evidence": "verbatim span or empty"\#(pageHint)}"#,
            options: GenerationOptions(maxTokens: 256, temperature: 0.0)
        )
        guard let onPartialAnswer else {
            return cleanAnswer(
                try await runner.run(task, images: pages),
                pageCount: pageCount
            )
        }
        var accumulated = ""
        var lastPublished = ""
        for try await chunk in runner.backend.stream(
            prompt: task.composedPrompt(),
            system: task.system,
            images: pages,
            options: task.options
        ) {
            accumulated += chunk
            if let partial = partialAnswer(in: accumulated), partial != lastPublished {
                lastPublished = partial
                onPartialAnswer(partial)
            }
        }
        if let data = JSONExtraction.data(from: accumulated),
           let raw = try? JSONDecoder().decode(AnswerRaw.self, from: data) {
            return cleanAnswer(raw, pageCount: pageCount)
        }
        guard !lastPublished.isEmpty else {
            throw VLMKitError.decodingFailed(raw: accumulated)
        }
        return DocumentAnswer(
            answer: lastPublished.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: nil,
            page: nil
        )
    }

    /// Trim the strings, turn an empty `evidence` into `nil`, and convert the
    /// model's 1-indexed page (or nil/0/out-of-range) to a 0-indexed `Int?`.
    static func cleanAnswer(_ raw: AnswerRaw, pageCount: Int = 1) -> DocumentAnswer {
        let trimmedEvidence = raw.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let page: Int? = {
            guard pageCount > 1, let oneIndexed = raw.page, (1...pageCount).contains(oneIndexed) else {
                return nil
            }
            return oneIndexed - 1
        }()
        return DocumentAnswer(
            answer: raw.answer.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: (trimmedEvidence?.isEmpty == false) ? trimmedEvidence : nil,
            page: page
        )
    }

    /// Locate each extracted field's value on the page from an OCR pass. The
    /// caller runs the OCR (Vision, Tesseract, …) and hands the observations in;
    /// this matching layer is OCR-engine-agnostic.
    ///
    /// Matching is case-insensitive, full-width→half-width folded (so "ＸＪ-１００"
    /// matches "XJ-100"), and whitespace-collapsed. When several observations
    /// contain the same value, the **tightest** one wins (the shortest containing
    /// observation — assumed to be the most precise box around the value rather
    /// than a wide line that happens to mention it). Matches are constrained to
    /// the field's own page so a value on page 3 isn't accidentally boxed against
    /// an identical string on page 1.
    ///
    /// Returns: `fieldIndex` → image-normalized box (0...1, top-left) on
    /// `fields[fieldIndex].page`. Fields without a match are simply absent — the
    /// caller can render the row without a box (graceful degradation, no crash).
    public static func locate(
        fields: [DocumentField],
        in observations: [OCRObservation]
    ) -> [Int: CGRect] {
        let normalized = observations.map { (text: normalize($0.text), box: $0.box, page: $0.page) }
        var result: [Int: CGRect] = [:]
        for (index, field) in fields.enumerated() {
            let needle = normalize(field.value)
            guard !needle.isEmpty else { continue }
            var bestBox: CGRect?
            var bestTightness: Double = 0
            for entry in normalized where entry.page == field.page {
                guard !entry.text.isEmpty, entry.text.contains(needle) else { continue }
                let tightness = Double(needle.count) / Double(entry.text.count)
                if tightness > bestTightness {
                    bestTightness = tightness
                    bestBox = entry.box
                }
            }
            if let bestBox { result[index] = bestBox }
        }
        return result
    }

    /// The running text of the JSON `"answer"` field as it accumulates during a
    /// streaming ask. Returns nil until the value's opening quote appears, then a
    /// growing string until the closing quote. Handles the common escape
    /// sequences (`\n`, `\t`, `\"`, `\\`, `\/`). A trailing `\` (escape pending
    /// its escapee) holds off rather than emit a partial, so the returned string
    /// only contains finished characters. Internal so tests can pin the shape.
    static func partialAnswer(in accumulated: String) -> String? {
        guard let keyRange = accumulated.range(of: #""answer""#) else { return nil }
        // Skip whitespace/colon between `"answer"` and the opening quote.
        var index = keyRange.upperBound
        while index < accumulated.endIndex, accumulated[index] != "\"" {
            index = accumulated.index(after: index)
        }
        guard index < accumulated.endIndex else { return nil }
        var cursor = accumulated.index(after: index)  // skip opening quote
        var result = ""
        while cursor < accumulated.endIndex {
            let c = accumulated[cursor]
            if c == "\\" {
                let next = accumulated.index(after: cursor)
                guard next < accumulated.endIndex else { break }  // pending escape
                switch accumulated[next] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                default: result.append(accumulated[next])
                }
                cursor = accumulated.index(after: next)
            } else if c == "\"" {
                return result  // closing quote
            } else {
                result.append(c)
                cursor = accumulated.index(after: cursor)
            }
        }
        return result
    }

    /// Lower-case, full-width→half-width fold, and whitespace-collapse — the
    /// minimum so "ＸＪ-１００" matches "XJ-100" and "Frame No.   XJ-100" matches
    /// "Frame No. XJ-100". Internal so tests can pin the shape; not promised as
    /// public API.
    static func normalize(_ text: String) -> String {
        let folded = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return folded
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
