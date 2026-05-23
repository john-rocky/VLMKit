/// A field to read off a form or document.
public struct FormField: Sendable {
    public let name: String
    /// Optional hint about what/where the value is (e.g. "top-right, ISO date").
    public let description: String?

    public init(_ name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// α7 — Form / document field extraction. A single typed VLM call over the whole
/// document returns one value per requested field. Demonstrates the typed
/// `VLMTask<Output>` path with a caller-defined set of fields.
public enum FormExtraction {
    /// Returns a map of field name → extracted value ("" when a field is absent).
    public static func extract(
        fields: [FormField],
        from image: VLMImage,
        runner: VLMRunner
    ) async throws -> [String: String] {
        let described = fields
            .map { field in field.description.map { "\(field.name) (\($0))" } ?? field.name }
            .joined(separator: ", ")
        let shape = "{" + fields.map { "\"\($0.name)\": \"value or empty string\"" }.joined(separator: ", ") + "}"

        let task = VLMTask<[String: String]>(
            instruction: """
            Read this form or document and extract the value for each of these \
            fields: \(described). If a field is not present, use an empty string. \
            Return one JSON object keyed by the exact field names.
            """,
            jsonHint: shape,
            options: GenerationOptions(maxTokens: 768, temperature: 0.0)
        )
        return try await runner.run(task, images: [image])
    }
}
