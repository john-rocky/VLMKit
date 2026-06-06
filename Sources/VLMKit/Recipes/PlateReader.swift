import CoreGraphics
import Foundation

/// Read every reading on a data plate / nameplate / rating plate / caution plate,
/// meter, or gauge — typically a cropped close-up — as `{label, value}` pairs.
///
/// This is deliberately different from `DocumentQA.extract`, which targets full
/// documents: that prompt asks for the *printed field name* as the label and skips
/// running prose. Plates break both assumptions — they often **stamp values with no
/// printed field name** (a bare "SCM-200", "100-240V", "1.6 MPa"), and caution plates
/// are mostly prose. So here the **value is required and the label is inferred** when
/// none is printed, and standalone readings are kept. Reuses `DocumentField` for the
/// result shape so the app renders it exactly like the other extraction demos.
public enum PlateReader {
    /// Lenient decode target: both fields are optional so one malformed entry (a missing
    /// `label` on a value-only reading, or a missing `value`) doesn't abort the whole
    /// read. `clean` then enforces a non-empty value and supplies a fallback label.
    struct ReadingRaw: Codable, Sendable {
        struct Field: Codable, Sendable {
            let label: String?
            let value: String?
        }
        let fields: [Field]
    }

    /// One VLM call → the readings on the plate. `maxFields` caps the list (the most
    /// important readings if the plate has more).
    public static func read(
        on image: VLMImage,
        runner: VLMRunner,
        maxFields: Int = 16
    ) async throws -> [DocumentField] {
        let task = VLMTask<ReadingRaw>(
            instruction: """
            You are reading the data plate, nameplate, rating plate, caution plate, \
            meter, or gauge shown in this image — usually a cropped close-up. Read \
            EVERY reading, marking, rating, and specification on it as label/value pairs.

            For each entry:
            - "value": the reading itself, copied verbatim exactly as printed, stamped, \
            or engraved — numbers, units, codes, model names, dates. This is REQUIRED \
            and must never be empty.
            - "label": the printed field name shown next to the value. If the plate \
            shows a value with NO printed field name, infer a short, accurate label for \
            it (e.g. "Model", "Serial number", "Voltage", "Max pressure", \
            "Manufacturer", "Date", "Rated power").

            Rules:
            - Every entry MUST have a non-empty value. Never output an entry whose value \
            is blank.
            - Include standalone values that have no printed field name — plates often \
            stamp readings without labels; give those an inferred label.
            - For a warning or caution line, use a short label like "Warning" or \
            "Caution" and the text as the value.
            - Copy only what you can actually read; do not invent or guess readings.
            - Return at most \(maxFields) entries — the most important ones if there are more.
            - Output one JSON object in the shape specified.
            """,
            jsonHint: #"{"fields": [{"label": "field name", "value": "reading"}]}"#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        let raw = try await runner.run(task, images: [image])
        return clean(raw.fields, maxFields: maxFields)
    }

    /// Trim, drop entries whose value is blank, supply a generic label when the model
    /// left it empty (a value-only reading), and cap to the limit. Order from the model
    /// is preserved — the VLM tends to read top-to-bottom, which matches the plate.
    static func clean(_ raw: [ReadingRaw.Field], maxFields: Int) -> [DocumentField] {
        var cleaned: [DocumentField] = []
        for field in raw {
            let value = (field.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            var label = (field.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = "Reading" }
            cleaned.append(DocumentField(label: label, value: value))
            if cleaned.count >= maxFields { break }
        }
        return cleaned
    }
}
