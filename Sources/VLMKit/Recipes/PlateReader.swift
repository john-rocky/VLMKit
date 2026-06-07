import CoreGraphics
import Foundation

/// An autonomous read of a data plate / nameplate / meter / gauge — typically a cropped
/// close-up. The VLM figures out **what the object is** on its own (`subject`) and then
/// reads **every item as a label/value pair** (`fields`): "what kind of device, what
/// items, what values", with nothing specified up front.
public struct PlateReading: Sendable {
    /// What the object is, in a few words the VLM infers — e.g. "residential gas meter",
    /// "motor nameplate", "electricity meter", "pressure gauge". Empty if it couldn't tell.
    public let subject: String
    /// Every reading on the object as a label/value pair, in reading order.
    public let fields: [DocumentField]

    public init(subject: String, fields: [DocumentField]) {
        self.subject = subject
        self.fields = fields
    }
}

/// Read a plate / nameplate / meter / gauge with one VLM call.
///
/// Deliberately different from `DocumentQA.extract` (full documents, printed field
/// names, skips prose): plates often **stamp values with no printed field name**, and
/// the shipped 4-bit model, given the document prompt, echoes each fragment into both
/// label and value instead of pairing them. Here the value is required, the label is
/// inferred when not printed, and the device type is identified — which makes even the
/// quantized model produce proper `{label, value}` pairs.
public enum PlateReader {
    /// Lenient decode target: every field is optional so one malformed entry doesn't
    /// abort the whole read. `clean` then enforces a non-empty value + fallback label.
    struct ReadingRaw: Codable, Sendable {
        struct Field: Codable, Sendable {
            let label: String?
            let value: String?
        }
        let subject: String?
        let fields: [Field]
    }

    /// One VLM call → what the object is + every reading on it. `maxFields` caps the
    /// list (the most important readings if there are more).
    public static func read(
        on image: VLMImage,
        runner: VLMRunner,
        maxFields: Int = 16
    ) async throws -> PlateReading {
        let task = VLMTask<ReadingRaw>(
            instruction: """
            You are reading the data plate, nameplate, rating plate, caution plate, \
            meter, gauge, or measuring device shown in this image — usually a cropped \
            close-up.

            First, in "subject", say what the object is in a few words — e.g. \
            "residential gas meter", "electricity meter", "water meter", "pressure \
            gauge", "motor nameplate", "appliance rating plate".

            Then in "fields", read EVERY reading, marking, rating, and specification on \
            it as label/value pairs.

            For each field:
            - "value": the reading itself, copied verbatim exactly as printed, stamped, \
            engraved, or shown on the dial — numbers, units, codes, model names, dates. \
            This is REQUIRED and must never be empty.
            - "label": the printed field name shown next to the value. If there is NO \
            printed field name, infer a short, accurate label (e.g. "Reading", "Index", \
            "Meter number", "Model", "Serial number", "Max flow", "Voltage", \
            "Manufacturer", "Date").

            Rules:
            - For a meter or gauge, the single most important field is the CURRENT \
            reading shown on the counter or dial — always include it (label "Reading" or \
            "Index", value the number with its unit, e.g. "01234 m³").
            - Every entry MUST have a non-empty value. Never output a blank value, and \
            never just repeat the label as the value.
            - Include standalone values that have no printed field name; give them an \
            inferred label.
            - For a warning or caution line, use a short label like "Warning" with the \
            text as the value.
            - Copy only what you can actually read; do not invent or guess.
            - Return at most \(maxFields) fields — the most important ones if there are more.
            - Output one JSON object in the shape specified.
            """,
            jsonHint: #"{"subject": "what this object is", "fields": [{"label": "field name", "value": "reading"}]}"#,
            options: GenerationOptions(maxTokens: 1024, temperature: 0.0)
        )
        let raw = try await runner.run(task, images: [image])
        return PlateReading(
            subject: (raw.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            fields: clean(raw.fields, maxFields: maxFields)
        )
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
