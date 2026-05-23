import CoreGraphics
import Vision

/// Regions of interest from Vision saliency — a generic "where are the objects"
/// extractor for when there's no task-specific detector. Runs on the Neural
/// Engine on device; saliency is unreliable on the Simulator.
public struct VisionObjectExtractor: RegionExtractor {
    public enum Mode: Sendable {
        /// Distinct foreground objects — best for "find each item".
        case objectness
        /// Where a viewer's attention is drawn — typically one salient area.
        case attention
    }

    public let mode: Mode
    public let maxRegions: Int

    public init(mode: Mode = .objectness, maxRegions: Int = 16) {
        self.mode = mode
        self.maxRegions = maxRegions
    }

    public func extractRegions(from image: VLMImage) throws -> [Region] {
        let request: VNImageBasedRequest = switch mode {
        case .objectness: VNGenerateObjectnessBasedSaliencyImageRequest()
        case .attention: VNGenerateAttentionBasedSaliencyImageRequest()
        }
        try VNImageRequestHandler(cgImage: image.cgImage, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects
        else { return [] }
        return objects.prefix(maxRegions).map { object in
            Region(boundingBox: Self.topLeft(object.boundingBox), confidence: object.confidence)
        }
    }

    /// Convert Vision's normalized bottom-left rect to VLMKit's top-left rect.
    private static func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}
