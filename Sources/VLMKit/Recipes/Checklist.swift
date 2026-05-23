public struct ChecklistItem: Sendable {
    public let id: String
    public let requirement: String

    public init(id: String, requirement: String) {
        self.id = id
        self.requirement = requirement
    }
}

public struct ChecklistResult: Codable, Sendable {
    public let id: String
    public let passed: Bool
    public let reason: String
}

public struct ChecklistReport: Codable, Sendable {
    public let results: [ChecklistResult]
    public var passedCount: Int { results.filter(\.passed).count }
    public var total: Int { results.count }
}

/// α11 — Multi-item checklist. Task-axis fan-out: each requirement is evaluated
/// in its own VLM call against the same image, then the verdicts are collected.
/// Independent calls keep one item's reasoning from bleeding into another's and
/// let each verdict carry its own justification — the basis for compliance (ζ)
/// recipes later. A failing item is recorded as not-passed rather than aborting.
public enum Checklist {
    public static func evaluate(
        items: [ChecklistItem],
        on image: VLMImage,
        runner: VLMRunner,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> ChecklistReport {
        struct Judgment: Codable, Sendable {
            let passed: Bool
            let reason: String
        }

        var results: [ChecklistResult] = []
        for (index, item) in items.enumerated() {
            let task = VLMTask<Judgment>(
                instruction: """
                Evaluate the image against this single requirement and decide whether \
                it is satisfied.
                Requirement: \(item.requirement)
                """,
                jsonHint: #"{"passed": true or false, "reason": "short explanation"}"#,
                options: GenerationOptions(maxTokens: 256, temperature: 0.0)
            )
            do {
                let judgment = try await runner.run(task, images: [image])
                results.append(ChecklistResult(id: item.id, passed: judgment.passed, reason: judgment.reason))
            } catch {
                results.append(ChecklistResult(id: item.id, passed: false, reason: "evaluation failed: \(error)"))
            }
            onProgress?(index + 1, items.count)
        }
        return ChecklistReport(results: results)
    }
}
