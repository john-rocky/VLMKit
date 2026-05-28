import CoreGraphics
import Vision

/// Person regions from Vision's on-device human detector. This extractor is
/// VLMKit's core thesis in one line: let an Apple framework decide *where* the
/// people are, then fan out a VLM to profile each one. One region per detected
/// person — no grid double-counting — and the boxes come straight from Vision, so
/// the VLM is never asked to localize anything. Runs on the Neural Engine;
/// detection is unreliable on the Simulator.
public struct VisionPersonExtractor: RegionExtractor {
    public let maxRegions: Int
    /// Fraction to grow each detected box on every side, so the crop keeps the whole
    /// person plus a little surrounding context for the VLM.
    public let padding: CGFloat

    public init(maxRegions: Int = 24, padding: CGFloat = 0.08) {
        self.maxRegions = maxRegions
        self.padding = max(0, padding)
    }

    public func extractRegions(from image: VLMImage) throws -> [Region] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        try VNImageRequestHandler(cgImage: image.cgImage, options: [:]).perform([request])
        let people = (request.results as? [VNHumanObservation] ?? []).prefix(maxRegions)
        return people.map { person in
            Region(
                boundingBox: Self.topLeftPadded(person.boundingBox, padding: padding),
                label: "person",
                confidence: person.confidence
            )
        }
    }

    /// Convert Vision's normalized bottom-left rect to VLMKit's top-left rect,
    /// grown by `padding` on each side and clamped to the image.
    private static func topLeftPadded(_ rect: CGRect, padding: CGFloat) -> CGRect {
        let dx = rect.width * padding, dy = rect.height * padding
        return CGRect(
            x: rect.minX - dx,
            y: (1 - rect.maxY) - dy,
            width: rect.width + 2 * dx,
            height: rect.height + 2 * dy
        ).clampedToUnitSquare()
    }
}
