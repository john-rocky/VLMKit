import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Composes a lifted subject onto a generated background. Output is a square
/// marketplace-friendly canvas (1024×1024 by default) with the subject scaled
/// to fit comfortably with breathing room and a soft drop shadow grounding it
/// against the background. Pure Core Image — runs on the GPU and stays
/// off-device-free (no external assets).
struct BackgroundCompositor {

    /// Default output canvas. Mercari / eBay / Yahoo all accept square crops
    /// and many display them better than odd ratios.
    static let defaultCanvas = CGSize(width: 1024, height: 1024)
    /// Subject occupies this fraction of the canvas's shorter side. Sized to
    /// leave the backdrop clearly visible — a hero photo whose background is
    /// just a thin frame around the product looks like a cut-out, not a
    /// staged shot. Around 60% feels "placed in a scene" while still keeping
    /// the product the focal point.
    static let subjectFraction: CGFloat = 0.6
    /// Vertical placement bias. Slightly below center reads as "on a
    /// surface" rather than floating.
    static let subjectVerticalBias: CGFloat = 0.06

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Compose `subject` (lifted to transparent) on `background`. Returns nil
    /// only if Core Image fails to produce a final CGImage (rare; usually only
    /// happens with corrupt input).
    func compose(
        subject: LiftedSubject,
        background: UIImage,
        canvas: CGSize = BackgroundCompositor.defaultCanvas
    ) -> UIImage? {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        // 1. Background: cover-fill the canvas, preserving aspect.
        guard let bgCG = background.cgImage,
              let bgFitted = coverFill(bgCG, into: canvasRect) else {
            return nil
        }
        let backgroundCI = CIImage(cgImage: bgFitted)

        // 2. Subject: scale to fit + drop-shadow.
        let subjectCI = CIImage(cgImage: subject.image)
        let subjectSize = subjectCI.extent.size
        let shorter = min(canvas.width, canvas.height)
        let scale = (shorter * Self.subjectFraction)
            / max(subjectSize.width, subjectSize.height)
        let scaled = subjectCI.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledSize = scaled.extent.size
        let originX = (canvas.width - scaledSize.width) / 2
        // y in CI is bottom-up; bias down by subtracting the bias from center.
        let originY = (canvas.height - scaledSize.height) / 2
            - canvas.height * Self.subjectVerticalBias
        let placed = scaled.transformed(
            by: CGAffineTransform(translationX: originX, y: originY)
        )

        // 3. Soft shadow: take the subject's alpha channel, blur, darken,
        // offset down a few pixels. Cheap and reads as "grounded on a surface".
        let shadow = makeShadow(for: placed)

        // 4. Composite: background → shadow → subject.
        let composed = placed
            .composited(over: shadow.composited(over: backgroundCI))
            .cropped(to: canvasRect)

        guard let cg = context.createCGImage(composed, from: canvasRect) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - Helpers

    /// Scale-and-crop `cg` so it fills `rect` while preserving aspect — short
    /// side matches, long side gets center-cropped. Returns nil on failure.
    private func coverFill(_ cg: CGImage, into rect: CGRect) -> CGImage? {
        let imageSize = CGSize(width: cg.width, height: cg.height)
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let scaledSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        let image = renderer.image { ctx in
            let originX = (rect.width - scaledSize.width) / 2
            let originY = (rect.height - scaledSize.height) / 2
            ctx.cgContext.draw(cg, in: CGRect(origin: CGPoint(x: originX, y: originY), size: scaledSize))
        }
        return image.cgImage
    }

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
