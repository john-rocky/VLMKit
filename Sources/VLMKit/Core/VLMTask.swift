/// A single typed VLM call: an instruction plus the `Decodable` type its JSON
/// response decodes into. `VLMRunner` composes the prompt, runs it, and decodes.
public struct VLMTask<Output: Decodable & Sendable>: Sendable {
    public var instruction: String
    public var system: String?
    /// Human-readable description of the expected JSON shape, appended to the
    /// prompt — e.g. `#"[{"name": "string", "brand": "string or null"}]"#`.
    public var jsonHint: String?
    public var options: GenerationOptions

    public init(
        instruction: String,
        system: String? = nil,
        jsonHint: String? = nil,
        options: GenerationOptions = .init()
    ) {
        self.instruction = instruction
        self.system = system
        self.jsonHint = jsonHint
        self.options = options
    }

    /// Instruction plus the JSON-only directive that gets sent to the model.
    func composedPrompt() -> String {
        var prompt = instruction
        prompt += "\n\nRespond with ONLY valid JSON — no markdown, no code fences, no commentary."
        if let jsonHint {
            prompt += " Match this shape exactly:\n\(jsonHint)"
        }
        return prompt
    }
}
