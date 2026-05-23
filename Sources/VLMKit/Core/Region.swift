import CoreGraphics
import Foundation

/// A region of interest within an image.
///
/// `boundingBox` is normalized with a **top-left origin** (x, y, width, height
/// all in `0...1`, y increasing downward) — matching `VLMImage` and
/// `CGImage.cropping(to:)`. Vision-based extractors convert from Vision's
/// bottom-left convention.
public struct Region: Identifiable, Sendable {
    public let id: UUID
    public let boundingBox: CGRect
    /// Optional hint from the extractor (e.g. a Vision class label).
    public let label: String?
    public let confidence: Float?

    public init(boundingBox: CGRect, label: String? = nil, confidence: Float? = nil) {
        self.id = UUID()
        self.boundingBox = boundingBox
        self.label = label
        self.confidence = confidence
    }
}

/// Given an image, return the regions to run the VLM on. The first stage of a
/// fan-out: Apple frameworks (Vision, a grid, LiDAR…) decide *where* to look.
public protocol RegionExtractor: Sendable {
    func extractRegions(from image: VLMImage) async throws -> [Region]
}
