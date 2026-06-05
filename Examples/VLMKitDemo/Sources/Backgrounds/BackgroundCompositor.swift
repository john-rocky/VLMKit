import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// Composes a lifted subject onto a generated background. The output keeps
/// the background's native aspect ratio (no cover-fill crop — users want to
/// see the WHOLE scene they picked), and the subject is scaled to take up
/// the lion's share of the canvas. Pure Core Image — runs on the GPU and
/// stays off-device-free (no external assets).
struct BackgroundCompositor {

    /// Target longest-side budget for the output. The actual output size
    /// follows the background's aspect ratio, capped to this on the long
    /// side. A 4000×2700 Pexels photo renders at 1024×691; a 512×512
    /// HyperSD frame renders at 512×512 (we don't upscale beyond source).
    static let defaultCanvas = CGSize(width: 1024, height: 1024)
    /// Subject occupies this fraction of the canvas's shorter side. Sized
    /// to take the foreground while leaving a clear ring of background
    /// visible — the user explicitly wanted the product BIG with the full
    /// background still readable.
    static let subjectFraction: CGFloat = 0.85
    /// Vertical placement bias used as a fallback when Vision saliency
    /// fails. Slightly below center reads as "on a surface" rather than
    /// floating. Normal path uses saliency-based placement instead.
    static let fallbackVerticalBias: CGFloat = 0.04
    /// How strongly to prefer the lower half of the frame over the upper
    /// half. Product photos read more naturally with the item sitting
    /// "on" a surface (lower half) than floating in negative sky (upper
    /// half), so we add this much to the saliency score for top-area
    /// candidates. 0 = no bias, 1 = treat top as fully salient.
    private static let lowerHalfPreference: Float = 0.4

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Compose `subject` (lifted to transparent) on `background`. The
    /// returned image's aspect ratio matches the background's, capped to
    /// `canvas`'s longest side. Returns nil only if Core Image fails to
    /// produce a final CGImage (rare; usually only with corrupt input).
    func compose(
        subject: LiftedSubject,
        background: UIImage,
        canvas: CGSize = BackgroundCompositor.defaultCanvas
    ) -> UIImage? {
        guard let bgCG = background.cgImage else { return nil }

        // Output canvas keeps the background's aspect — the user wants the
        // entire scene visible, no cover-fill crop. Scale the background
        // down (never up) to fit within `canvas`'s longest side.
        let bgSize = CGSize(width: bgCG.width, height: bgCG.height)
        let longestSourceSide = max(bgSize.width, bgSize.height)
        let longestTargetSide = max(canvas.width, canvas.height)
        let bgScale = min(1, longestTargetSide / longestSourceSide)
        let outputSize = CGSize(
            width: round(bgSize.width * bgScale),
            height: round(bgSize.height * bgScale)
        )
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let backgroundCI = CIImage(cgImage: bgCG)
            .transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))

        // Subject: scale up to the configured fraction of the SHORTER
        // output side so it stays comfortably inside the frame for both
        // portrait and landscape backgrounds.
        let subjectCI = CIImage(cgImage: subject.image)
        let subjectSize = subjectCI.extent.size
        let shorter = min(outputSize.width, outputSize.height)
        let scale = (shorter * Self.subjectFraction)
            / max(subjectSize.width, subjectSize.height)
        let scaled = subjectCI.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledSize = scaled.extent.size
        // Find the spot on the (already-fitted) background where the subject
        // covers the least visually-salient region. Saliency runs on the
        // ORIGINAL background CGImage; the result is in normalized [0,1]
        // coordinates so it transfers to the scaled output directly.
        let centerTopLeft = Self.bestSubjectCenter(
            in: bgCG,
            outputSize: outputSize,
            subjectSize: scaledSize
        )
        let originX = centerTopLeft.x - scaledSize.width / 2
        // y in CI is bottom-up; saliency returned top-left coordinates, flip.
        let originY = outputSize.height - centerTopLeft.y - scaledSize.height / 2
        let placed = scaled.transformed(
            by: CGAffineTransform(translationX: originX, y: originY)
        )

        // Soft shadow: take the subject's alpha channel, blur, darken,
        // offset down a few pixels. Cheap and reads as "grounded on a surface".
        let shadow = makeShadow(for: placed)

        // Composite: background → shadow → subject.
        let composed = placed
            .composited(over: shadow.composited(over: backgroundCI))
            .cropped(to: outputRect)

        guard let cg = context.createCGImage(composed, from: outputRect) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - Saliency-based placement

    /// Pick the (x, y) center on the `outputSize` canvas where placing a
    /// `subjectSize` window minimizes how much of the background's salient
    /// region is occluded. Returns top-left-origin coordinates.
    ///
    /// Strategy: run Vision's attention-based saliency on the background,
    /// slide the subject-sized window across the saliency map at a coarse
    /// step, sum saliency under the window for each position, pick the
    /// minimum. A vertical-position bias nudges results toward the lower
    /// half of the frame so products read as "sitting on a surface" rather
    /// than floating. Falls back to centered-with-bottom-bias if Vision
    /// produces no observation.
    static func bestSubjectCenter(
        in backgroundCG: CGImage,
        outputSize: CGSize,
        subjectSize: CGSize
    ) -> CGPoint {
        let fallback = CGPoint(
            x: outputSize.width / 2,
            y: outputSize.height * (0.5 + fallbackVerticalBias)
        )
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: backgroundCG, options: [:])
        do { try handler.perform([request]) } catch { return fallback }
        guard
            let observation = request.results?.first as? VNSaliencyImageObservation
        else { return fallback }

        let buf = observation.pixelBuffer
        let salWidth = CVPixelBufferGetWidth(buf)
        let salHeight = CVPixelBufferGetHeight(buf)
        guard salWidth > 0, salHeight > 0 else { return fallback }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return fallback }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.size
        let buffer = base.assumingMemoryBound(to: Float32.self)

        // Build an integral image of the saliency map so each window-sum
        // costs O(1) instead of O(window) — important when the search
        // grid is dense.
        var integral = [Float](repeating: 0, count: (salWidth + 1) * (salHeight + 1))
        let integralRowStride = salWidth + 1
        for y in 0..<salHeight {
            var rowSum: Float = 0
            for x in 0..<salWidth {
                let pixel = buffer[y * floatsPerRow + x]
                rowSum += pixel
                integral[(y + 1) * integralRowStride + (x + 1)] =
                    integral[y * integralRowStride + (x + 1)] + rowSum
            }
        }

        // Subject window in saliency-map pixels.
        let winW = max(1, Int((subjectSize.width / outputSize.width) * CGFloat(salWidth)))
        let winH = max(1, Int((subjectSize.height / outputSize.height) * CGFloat(salHeight)))
        guard winW < salWidth, winH < salHeight else { return fallback }

        let stepX = max(1, winW / 8)
        let stepY = max(1, winH / 8)
        var bestScore: Float = .infinity
        var bestX = (salWidth - winW) / 2
        var bestY = (salHeight - winH) / 2
        let windowArea = Float(winW * winH)

        var y = 0
        while y + winH <= salHeight {
            var x = 0
            while x + winW <= salWidth {
                let a = integral[y * integralRowStride + x]
                let b = integral[y * integralRowStride + (x + winW)]
                let c = integral[(y + winH) * integralRowStride + x]
                let d = integral[(y + winH) * integralRowStride + (x + winW)]
                let sum = d - b - c + a
                var score = sum / windowArea
                // Penalize the upper half so the subject doesn't end up
                // floating against the sky / ceiling. Top edge gets the
                // full `lowerHalfPreference` bonus added to its score
                // (higher = worse); bottom gets 0.
                let yCenterNorm = Float(y + winH / 2) / Float(salHeight)
                if yCenterNorm < 0.5 {
                    score += lowerHalfPreference * (0.5 - yCenterNorm) * 2
                }
                if score < bestScore {
                    bestScore = score
                    bestX = x
                    bestY = y
                }
                x += stepX
            }
            y += stepY
        }

        // Saliency coords → output canvas coords (top-left origin).
        let centerSalX = CGFloat(bestX) + CGFloat(winW) / 2
        let centerSalY = CGFloat(bestY) + CGFloat(winH) / 2
        return CGPoint(
            x: centerSalX / CGFloat(salWidth) * outputSize.width,
            y: centerSalY / CGFloat(salHeight) * outputSize.height
        )
    }

    // MARK: - Helpers

    /// Build a soft drop shadow from the placed subject's alpha. The shadow
    /// CIImage is positioned identically to the subject minus a small
    /// downward offset — composited under the subject in the final blend.
    private func makeShadow(for placedSubject: CIImage) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = placedSubject
        blur.radius = 28
        let blurred = blur.outputImage ?? placedSubject

        let darken = CIFilter.colorMatrix()
        darken.inputImage = blurred
        // Zero out RGB, keep alpha → pure black silhouette at the subject's shape.
        darken.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        darken.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        darken.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        darken.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.35)
        let silhouette = darken.outputImage ?? blurred

        return silhouette.transformed(
            by: CGAffineTransform(translationX: 0, y: -placedSubject.extent.height * 0.04)
        )
    }
}
