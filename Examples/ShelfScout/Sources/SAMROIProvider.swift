import CoreGraphics
import Foundation
import SAMKit

/// Turns a tap (or center) point into a region of interest using on-device MobileSAM.
///
/// VLMKit stays SAM-agnostic — this provider lives in the app, owning the SAMKit
/// dependency and the bundled `.mlpackage` models. Give it the captured image once
/// (`setImage`), then ask for the region at any image point (`roi(atImagePoint:)`); it
/// returns a tight, image-normalized (0...1, top-left) bounding box, ready to crop the
/// high-res detail from and to draw on the photo. The heavy Core ML work runs off the
/// main thread so taps stay responsive.
@MainActor
final class SAMROIProvider: ObservableObject {
    /// True once MobileSAM has loaded and can segment.
    @Published private(set) var isReady = false
    /// True if the bundled models could not be loaded (e.g. not downloaded yet).
    @Published private(set) var loadFailed = false

    private var session: SamSession?
    private var imageReady = false

    /// Load MobileSAM from the bundled models. Safe to call repeatedly (no-op once loaded).
    func loadIfNeeded() async {
        guard session == nil else { return }
        do {
            let model = try SamModelRef.bundled(.mobileSam)
            let config = RuntimeConfig(computeUnits: .bestAvailable, enableFP16: true)
            session = try await Task.detached(priority: .userInitiated) {
                try SamSession(model: model, config: config)
            }.value
            isReady = true
        } catch {
            loadFailed = true
            print("[SAMROIProvider] MobileSAM load failed: \(error)")
        }
    }

    /// Encode a freshly captured image. Run once per image — the encoder result is
    /// cached, so each later `roi(atImagePoint:)` only runs the fast decoder.
    func setImage(_ cgImage: CGImage) async {
        guard let session else { return }
        imageReady = false
        do {
            try await Task.detached(priority: .userInitiated) {
                try session.setImage(cgImage)
            }.value
            imageReady = true
        } catch {
            print("[SAMROIProvider] setImage failed: \(error)")
        }
    }

    /// Segment the object at an image-pixel point and return its tight, normalized
    /// (0...1, top-left) bounding box, or nil if nothing was segmented.
    func roi(atImagePoint point: CGPoint) async -> CGRect? {
        guard let session, imageReady else { return nil }
        let prompt = SamPoint(x: point.x, y: point.y, label: .positive)
        do {
            let mask = try await Task.detached(priority: .userInitiated) { () -> SamMask? in
                let result = try session.predict(points: [prompt])
                return result.masks.max { $0.score < $1.score }   // best of the multimask outputs
            }.value
            return mask.flatMap { Self.normalizedBoundingBox(of: $0) }
        } catch {
            print("[SAMROIProvider] predict failed: \(error)")
            return nil
        }
    }

    /// The tight bounding box of a mask's foreground, normalized to 0...1 (top-left
    /// origin) and padded slightly. SAM removes the letterbox padding, so the mask is
    /// already at the source image's aspect ratio — dividing by its own width/height
    /// yields image-normalized coordinates directly. Returns nil for an empty mask.
    static func normalizedBoundingBox(of mask: SamMask, padding: CGFloat = 0.04) -> CGRect? {
        let w = mask.width, h = mask.height
        guard w > 0, h > 0, mask.alpha.count >= w * h else { return nil }

        var minX = w, minY = h, maxX = -1, maxY = -1
        mask.alpha.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where p[row + x] >= 128 {   // foreground: sigmoid alpha ≥ 0.5
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        let box = CGRect(
            x: CGFloat(minX) / CGFloat(w),
            y: CGFloat(minY) / CGFloat(h),
            width: CGFloat(maxX - minX + 1) / CGFloat(w),
            height: CGFloat(maxY - minY + 1) / CGFloat(h)
        ).insetBy(dx: -padding, dy: -padding)   // grow slightly so the crop keeps context
        return box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
