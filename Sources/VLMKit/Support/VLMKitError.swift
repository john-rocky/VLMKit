import CoreGraphics
import Foundation

public enum VLMKitError: Error, CustomStringConvertible {
    /// A backend method was called before its model finished loading.
    case modelNotLoaded
    /// An image file could not be decoded.
    case imageLoadFailed(URL)
    /// The model produced output that could not be parsed into the requested
    /// type after all retries. Carries the raw text for debugging.
    case decodingFailed(raw: String)

    public var description: String {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded. Call load() on the backend first."
        case .imageLoadFailed(let url):
            return "Failed to load image at \(url.path)."
        case .decodingFailed(let raw):
            return "Could not decode structured output from model response:\n\(raw)"
        }
    }
}

extension CGRect {
    /// Clamp the rectangle to the unit square `0...1` on both axes.
    func clampedToUnitSquare() -> CGRect {
        let x = Swift.max(0, Swift.min(1, minX))
        let y = Swift.max(0, Swift.min(1, minY))
        let maxX = Swift.max(0, Swift.min(1, self.maxX))
        let maxY = Swift.max(0, Swift.min(1, self.maxY))
        return CGRect(x: x, y: y, width: Swift.max(0, maxX - x), height: Swift.max(0, maxY - y))
    }
}
