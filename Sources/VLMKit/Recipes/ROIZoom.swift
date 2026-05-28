import CoreGraphics
import Foundation

/// P5 — High-resolution ROI zoom. A two-stage, hierarchical read: one low-resolution
/// pass over the whole image for context, then a second pass over a cropped region of
/// interest at full resolution for fine detail.
///
/// This targets the VLM's "downsamples the input, loses detail" weakness. The backend
/// caps every call to a pixel budget (~0.79 MP), so a whole-image pass spreads that
/// budget across the entire scene; cropping the ROI from the *original* image first
/// spends the whole budget on that one region — so the detail pass can read small text,
/// markings, textures, or defects the overview cannot. Where the ROI comes from (an
/// Apple segmenter, a tap, the image center) is the caller's concern; this recipe only
/// needs a normalized rect.
public enum ROIZoom {
    /// Stage 1 — a short description of the whole scene (low effective resolution).
    public static func overview(on image: VLMImage, runner: VLMRunner) async throws -> String {
        let result = try await runner.runText(
            instruction: """
            Describe this whole image in one or two sentences: the overall scene and \
            the main subjects.
            """,
            images: [image],
            options: GenerationOptions(maxTokens: 200, temperature: 0.2)
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stage 2 — a detailed read of one region. `roi` is image-normalized (top-left
    /// origin, 0...1); the crop is taken from the full-resolution image. With a
    /// `question`, answers it about the region; otherwise describes the fine detail.
    public static func detail(
        on image: VLMImage,
        roi: CGRect,
        runner: VLMRunner,
        question: String? = nil
    ) async throws -> String {
        let crop = image.cropped(to: roi)
        let instruction: String
        if let q = question?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            instruction = """
            This is a zoomed-in, high-resolution crop of one region of a larger photo. \
            Answer this question about what is visible in this region, based only on \
            what you can see:
            \(q)
            """
        } else {
            instruction = """
            This is a zoomed-in, high-resolution crop of one region of a larger photo. \
            Describe in fine detail what is visible in THIS region — small text, \
            markings, textures, materials, condition, or defects — the kind of detail a \
            view of the whole image would miss. Be specific and objective.
            """
        }
        let result = try await runner.runText(
            instruction: instruction,
            images: [crop],
            options: GenerationOptions(maxTokens: 300, temperature: 0.2)
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
