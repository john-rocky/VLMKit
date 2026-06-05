import CoreImage
import UIKit
import Vision

/// Apply Apple's document detection + perspective correction to a still photo.
///
/// `VNDocumentCameraViewController` rectifies pages it captures live; this is
/// the still-image equivalent for photos chosen from the library: Vision's
/// document segmentation finds the page's quadrilateral and Core Image's
/// `CIPerspectiveCorrection` flattens it to a clean rectangle. Returns the
/// input unchanged when no document is found (or any step fails).
enum DocumentRectifier {
    static func rectify(_ image: UIImage) async -> UIImage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: rectifySync(image))
            }
        }
    }

    private static func rectifySync(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
        do {
            try handler.perform([request])
        } catch {
            return image
        }
        guard let observation = (request.results ?? []).first else { return image }

        // Build the CIImage in the same visual orientation Vision saw, so the
        // observation's normalized corners line up with this image's extent.
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = ciImage.extent
        let toPixel: (CGPoint) -> CIVector = { point in
            CIVector(x: point.x * extent.width, y: point.y * extent.height)
        }

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(toPixel(observation.topLeft), forKey: "inputTopLeft")
        filter.setValue(toPixel(observation.topRight), forKey: "inputTopRight")
        filter.setValue(toPixel(observation.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(toPixel(observation.bottomRight), forKey: "inputBottomRight")
        guard let output = filter.outputImage,
              let rectifiedCG = CIContext().createCGImage(output, from: output.extent)
        else { return image }
        return UIImage(cgImage: rectifiedCG)
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
