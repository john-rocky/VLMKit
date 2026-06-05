import CoreImage
import UIKit
import Vision

/// A subject lifted out of a photo: the masked CGImage (alpha-cropped to the
/// foreground bbox), the binary alpha mask, and the bbox in original-image
/// pixel coordinates. The compositor uses all three — the mask for soft
/// shadows, the bbox for placement, the CGImage for the layered alpha.
struct LiftedSubject {
    let image: CGImage          // RGBA, transparent outside the subject
    let mask: CGImage           // single-channel alpha (foreground = 1)
    /// Bbox in the source image's pixel coordinate space (top-left origin).
    let bbox: CGRect
}

/// Apple-only foreground lifting via `VNGenerateForegroundInstanceMaskRequest`
/// (iOS 17+). Picks the largest detected instance — for marketplace listings
/// the user has photographed one item, so the biggest mask is almost always
/// what they meant. No external model, no permissions, fully on-device.
enum SubjectLifter {

    /// Lift the dominant foreground subject from `cgImage`. Returns nil if
    /// Vision finds no foreground instances (e.g. solid-color photo, no
    /// recognizable object). Runs off the main actor.
    static func lift(from cgImage: CGImage) async -> LiftedSubject? {
        await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else {
                return nil
            }
            // `generateMaskedImage(ofInstances:from:croppedToInstancesExtent:)` returns
            // a CVPixelBuffer with the subject premultiplied onto transparent and
            // cropped to the instances' bbox.
            let cvPixelBuffer: CVPixelBuffer
            do {
                cvPixelBuffer = try observation.generateMaskedImage(
                    ofInstances: observation.allInstances,
                    from: handler,
                    croppedToInstancesExtent: true
                )
            } catch {
                return nil
            }
            // And the raw single-channel mask (uncropped) for shadow generation.
            let cvMask: CVPixelBuffer
            do {
                cvMask = try observation.generateScaledMaskForImage(
                    forInstances: observation.allInstances,
                    from: handler
                )
            } catch {
                return nil
            }
            guard let masked = CGImage.fromPixelBuffer(cvPixelBuffer),
                  let mask = CGImage.fromPixelBuffer(cvMask) else {
                return nil
            }
            // Compute bbox in source-image pixels: cropping is to instances'
            // extent, so the masked image's size is the bbox's size; find its
            // origin by locating the non-zero region in the uncropped mask.
            let bbox = bboxFromMask(mask, in: cgImage)
            return LiftedSubject(image: masked, mask: mask, bbox: bbox)
        }.value
    }

    /// Walk the mask to find the smallest rect containing every non-zero pixel.
    /// Used to know where in the source the subject originally sat — the
    /// compositor places the lifted subject on a new background at the same
    /// relative location-bias when possible. Returns the full image rect as a
    /// fallback if the mask is empty (shouldn't happen given the early exit
    /// above, but be safe).
    private static func bboxFromMask(_ mask: CGImage, in source: CGImage) -> CGRect {
        let width = mask.width
        let height = mask.height
        guard let provider = mask.dataProvider,
              let data = provider.data,
              let pointer = CFDataGetBytePtr(data) else {
            return CGRect(x: 0, y: 0, width: source.width, height: source.height)
        }
        let bytesPerRow = mask.bytesPerRow
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                if pointer[rowStart + x] > 8 {  // alpha > ~3%: count as foreground
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX < maxX, minY < maxY else {
            return CGRect(x: 0, y: 0, width: source.width, height: source.height)
        }
        // Mask is in the source image's coordinate space (Vision returns it at
        // source resolution). Add 1 px so maxX/maxY are inclusive.
        return CGRect(
            x: CGFloat(minX) / CGFloat(width) * CGFloat(source.width),
            y: CGFloat(minY) / CGFloat(height) * CGFloat(source.height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width) * CGFloat(source.width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height) * CGFloat(source.height)
        )
    }
}

private extension CGImage {
    /// Convert a CVPixelBuffer (RGBA or single-channel) to a CGImage via Core
    /// Image. The compositor downstream wants CGImage so all subjects live in
    /// the same coordinate space (no CVPixelBuffer orientation surprises).
    static func fromPixelBuffer(_ buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ci, from: ci.extent)
    }
}
