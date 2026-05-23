import CoreGraphics

/// Identity extractor — the whole image as a single region. Use it when a recipe
/// wants one VLM call over the entire image (a fan-out of one).
public struct FullImageExtractor: RegionExtractor {
    public init() {}

    public func extractRegions(from image: VLMImage) -> [Region] {
        [Region(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))]
    }
}
