import CoreGraphics
import Foundation

/// The VLM's answer for one person. With no question this is a free-form profile;
/// with a question it is the answer to that question. `summary` is the short form
/// shown on the photo, `description` the detailed form / justification.
public struct PersonProfile: Codable, Sendable {
    public let summary: String
    public let description: String
}

/// One person located by Vision and described/answered by the VLM. `box` is image-
/// normalized (top-left origin, 0...1) and comes straight from Vision's detector.
public struct CrowdPerson: Codable, Sendable {
    public let id: String
    public let summary: String
    public let description: String
    public let box: CGRect

    public init(id: String, summary: String, description: String, box: CGRect) {
        self.id = id
        self.summary = summary
        self.description = description
        self.box = box
    }
}

public struct CrowdReport: Codable, Sendable {
    public let totalPeople: Int
    public let people: [CrowdPerson]
}

/// α2 — Crowd analytics / per-person visual query. Apple's Vision detects each
/// person (region-axis fan-out driven by an on-device *detector* instead of a grid),
/// then one VLM call answers a `question` about each person crop — or, with no
/// question, profiles them with a detailed description. Pairing an Apple framework
/// with the VLM is the whole point: Vision says *where* the people are, the VLM says
/// *what about* each one (e.g. "Is this person wearing a hard hat?"). Per-person
/// crops also give the VLM far more effective resolution than one full-image pass.
public enum CrowdAnalytics {
    public static func pipeline(
        runner: VLMRunner,
        maxPeople: Int = 24,
        question: String? = nil
    ) -> FanoutPipeline<PersonProfile, CrowdReport> {
        FanoutPipeline(
            extractor: VisionPersonExtractor(maxRegions: maxPeople),
            runner: runner,
            makeTask: { _ in
                VLMTask(
                    instruction: instruction(for: question),
                    jsonHint: #"{"summary": "a few words", "description": "one or two detailed sentences"}"#,
                    options: GenerationOptions(maxTokens: 256, temperature: 0.2)
                )
            },
            aggregator: CrowdAggregator()
        )
    }

    public static func run(
        on image: VLMImage,
        runner: VLMRunner,
        maxPeople: Int = 24,
        question: String? = nil,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> CrowdReport {
        try await pipeline(runner: runner, maxPeople: maxPeople, question: question)
            .run(on: image, onProgress: onProgress)
    }

    /// Build the per-person instruction: answer the caller's question if one is
    /// given, otherwise fall back to a detailed description.
    private static func instruction(for question: String?) -> String {
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            return """
            You are looking at a single person cropped from a larger photo. \
            Answer this question about this one person, based only on what is \
            visible — do not guess identity:
            \(q)
            """
        }
        return """
        You are looking at a single person cropped from a larger photo. \
        Describe this one person in detail: apparent age range, gender presentation, \
        clothing and its colors, posture, and what they appear to be doing. \
        Be specific and objective; do not guess identity.
        """
    }
}

/// Collect each profiled person, tagging it with the Vision box it was cropped from.
struct CrowdAggregator: Aggregator {
    func callAsFunction(_ inputs: [RegionResult<PersonProfile>]) -> CrowdReport {
        let people = inputs.enumerated().map { index, result in
            CrowdPerson(
                id: "person-\(index + 1)",
                summary: result.output.summary,
                description: result.output.description,
                box: result.region.boundingBox
            )
        }
        return CrowdReport(totalPeople: people.count, people: people)
    }
}
