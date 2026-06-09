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
            You are reading a measuring instrument or its plate/label shown in this \
            image — a meter, gauge, dial, nameplate, rating plate, caution plate, or \
            product label, usually a cropped close-up.

            First, in "subject", name what it is precisely, using its scale or unit to \
            tell instruments apart — e.g. "pressure gauge", "thermometer", "voltmeter", \
            "ammeter", "residential gas meter", "water meter", "electricity meter", \
            "motor nameplate", "chemical product label".

            Then, in "fields", read it as label/value pairs:
            - If the instrument shows a CURRENT reading, give it as ONE field labeled \
            "Reading" (or "Index") with its unit — for an analog dial, estimate where \
            the NEEDLE points on the numbered scale (an approximate value is fine); for \
            a mechanical counter or digital display, copy the number (e.g. "415 V", \
            "13 bar", "10912 m³").
            - Then every printed specification and marking: manufacturer/brand, model, \
            serial number, measuring range, unit, accuracy class, standards, ratings, \
            dates.

            For each field:
            - "value": copied verbatim exactly as printed, stamped, or shown. This is \
            REQUIRED and must never be empty.
            - "label": the printed field name shown next to the value, or a short \
            inferred label when none is printed (e.g. "Manufacturer", "Model", "Range", \
            "Accuracy class", "Serial number", "Date").

            Rules:
            - Give only ONE "Reading" — the single current measured value. Do NOT list \
            the scale numbers, tick marks, or graduations (0, 20, 40, 60, …) as fields.
            - Do NOT repeat the same text as the value of several different fields, and \
            do NOT invent a manufacturer, model, or serial you cannot clearly read — \
            omit what is not there.
            - Every entry MUST have a non-empty value; never just repeat the label as \
            the value.
            - For a warning or caution line, use the label "Warning" with the text as \
            the value.
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
