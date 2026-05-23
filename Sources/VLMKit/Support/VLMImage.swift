import CoreGraphics
import CoreImage
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A platform-independent image VLMKit can crop and hand to a backend.
///
/// Backed by an immutable `CGImage` so it is safe to pass across tasks. All
/// region rectangles in VLMKit use a **normalized, top-left origin** coordinate
/// space (x and y in `0...1`, y increasing downward) — the natural orientation
/// for image pixels and `CGImage.cropping(to:)`.
public struct VLMImage: @unchecked Sendable {
    // CGImage is immutable and thread-safe, so @unchecked Sendable is sound.
    public let cgImage: CGImage

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    /// Load an image from a file URL using ImageIO (works on every Apple platform).
    public init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VLMKitError.imageLoadFailed(url)
        }
        self.cgImage = image
    }

    /// A `CIImage` view, used when handing the image to an MLX backend.
    public var ciImage: CIImage { CIImage(cgImage: cgImage) }

    /// Crop to a normalized rectangle (top-left origin). Returns `self` if the
    /// crop is empty or out of bounds.
    public func cropped(to normalizedRect: CGRect) -> VLMImage {
        let rect = normalizedRect.clampedToUnitSquare()
        let pixels = CGRect(
            x: rect.minX * CGFloat(width),
            y: rect.minY * CGFloat(height),
            width: rect.width * CGFloat(width),
            height: rect.height * CGFloat(height)
        ).integral
        guard pixels.width >= 1, pixels.height >= 1,
              let cropped = cgImage.cropping(to: pixels)
        else { return self }
        return VLMImage(cgImage: cropped)
    }
}

#if canImport(UIKit)
public extension VLMImage {
    init?(uiImage: UIImage) {
        guard let cgImage = uiImage.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }
}
#elseif canImport(AppKit)
public extension VLMImage {
    init?(nsImage: NSImage) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(cgImage: cgImage)
    }
}
#endif
