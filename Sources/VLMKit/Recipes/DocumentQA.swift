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
    public static func ask(
        _ question: String,
        on image: VLMImage,
        runner: VLMRunner
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
        let raw = try await runner.run(task, images: [image])
        return cleanAnswer(raw)
    }

    /// Trim the strings and turn an empty `evidence` into `nil`.
    static func cleanAnswer(_ raw: AnswerRaw) -> DocumentAnswer {
        let trimmedEvidence = raw.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentAnswer(
            answer: raw.answer.trimmingCharacters(in: .whitespacesAndNewlines),
            evidence: (trimmedEvidence?.isEmpty == false) ? trimmedEvidence : nil
        )
    }
}
