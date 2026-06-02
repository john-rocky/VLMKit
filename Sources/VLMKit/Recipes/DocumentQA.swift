import CoreGraphics
import Foundation

/// One labeled value the VLM read off a document — a key (the printed field name)
/// and its printed value, both copied verbatim from the page.
public struct DocumentField: Sendable, Codable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One OCR observation — a piece of recognized text and where it sits on the page.
/// `box` is image-normalized (0...1, top-left origin), matching VLMKit's convention.
/// Recipes accept this generic type so they stay OCR-engine-agnostic; the caller
/// runs the actual text recognition (Vision, Tesseract, …) and hands the
/// observations in.
public struct OCRObservation: Sendable, Equatable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
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

    /// Read every labeled key/value pair visible on the document.
    /// - `maxFields`: upper bound on returned pairs (default 16) — keeps the
    ///   response within the token budget on busy documents.
    public static func extract(
        on image: VLMImage,
        runner: VLMRunner,
        maxFields: Int = 16
    ) async throws -> DocumentExtraction {
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
            - Return at most \(maxFields) fields — the most prominent ones if the \
            page has more.
            - Output one JSON object in the shape specified.
            """,
            jsonHint: #"{"fields": [{"label": "printed field name", "value": "printed value"}]}"#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        let raw = try await runner.run(task, images: [image])
        return DocumentExtraction(fields: clean(raw.fields, maxFields: maxFields))
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
    }

    /// Answer a free-form natural-language question about the document, citing the
    /// supporting text when possible. `question` is the user's query in their own
    /// words — "What is the frame number?", "When does this expire?", "How much is
    /// the tax?".
    ///
    /// Pass `onPartialAnswer` to stream the `answer` field character-by-character
    /// as the model generates it — useful for a live typewriter UI so the user
    /// sees something appearing instead of staring at a spinner. The callback
    /// receives the answer-so-far each time it grows; the function still returns
    /// the final `DocumentAnswer` (with `evidence`) once generation completes.
    /// Streaming skips the JSON-parse retry the single-shot path uses; on parse
    /// failure it falls back to the partial answer with no evidence.
    public static func ask(
        _ question: String,
        on image: VLMImage,
        runner: VLMRunner,
        onPartialAnswer: (@Sendable (String) -> Void)? = nil
    ) async throws -> DocumentAnswer {
        let task = VLMTask<AnswerRaw>(
            instruction: """
            You are answering a question about a document — a form, machine plate, \
            label, invoice, receipt, business card, or any printed page.

            Question: \(question)

            Answer based ONLY on what is printed on the document.

            - "answer": a short, direct answer to the question, in the same \
            language as the question. If the document does not contain the \
            information, answer "Not stated".
            - "evidence": the verbatim phrase from the document that supports the \
            answer — a single short span, typically the label or the value. Use \
            an empty string if you cannot point to a specific span.
            """,
            jsonHint: #"{"answer": "short answer", "evidence": "verbatim span or empty"}"#,
            options: GenerationOptions(maxTokens: 256, temperature: 0.0)
        )
        guard let onPartialAnswer else {
            // Non-streaming path: VLMRunner.run handles the JSON-extract + retry.
            return cleanAnswer(try await runner.run(task, images: [image]))
        }
        // Streaming path: feed the live answer-so-far to the callback as tokens
        // arrive; at the end, parse the full JSON for `evidence`. No retry — the
        // user already saw partial text, so on parse failure fall back to the
        // partial answer with no evidence rather than re-running the call.
        var accumulated = ""
        var lastPublished = ""
        for try await chunk in runner.backend.stream(
            prompt: task.composedPrompt(),
            system: task.system,
            images: [image],
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
            return cleanAnswer(raw)
        }
        guard !lastPublished.isEmpty else {
            throw VLMKitError.decodingFailed(raw: accumulated)
        }
        return DocumentAnswer(
            answer: lastPublished.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: nil
        )
    }

    /// Trim the strings and turn an empty `evidence` into `nil`.
    static func cleanAnswer(_ raw: AnswerRaw) -> DocumentAnswer {
        let trimmedEvidence = raw.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentAnswer(
            answer: raw.answer.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: (trimmedEvidence?.isEmpty == false) ? trimmedEvidence : nil
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
    /// than a wide line that happens to mention it).
    ///
    /// Returns: `fieldIndex` → image-normalized box (0...1, top-left). Fields
    /// without a match are simply absent — the caller can render the row without
    /// a box (graceful degradation, no crash).
    public static func locate(
        fields: [DocumentField],
        in observations: [OCRObservation]
    ) -> [Int: CGRect] {
        let normalized = observations.map { (text: normalize($0.text), box: $0.box) }
        var result: [Int: CGRect] = [:]
        for (index, field) in fields.enumerated() {
            let needle = normalize(field.value)
            guard !needle.isEmpty else { continue }
            var bestBox: CGRect?
            var bestTightness: Double = 0
            for entry in normalized {
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
