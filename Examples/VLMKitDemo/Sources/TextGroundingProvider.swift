import Foundation
import CoreGraphics
import UIKit
import Combine

/// Turns a set of object-noun queries into image-normalized boxes using on-device
/// YOLOE open-vocabulary detection (the "point" half of Describe & Point).
///
/// VLMKit stays detector-agnostic — this provider lives in the app, owning the
/// `TextGroundingDetector` and the bundled YOLOE `.mlpackage`s. The VLM narrates
/// (a caption + which objects); this grounds those object nouns. Matching is exact
/// by `classIndex` = the position of the query in the array passed to `ground` —
/// no string fuzz. The heavy Core ML work runs off the main thread, mirroring
/// `SAMROIProvider`.
@MainActor
final class TextGroundingProvider: ObservableObject {
    /// True once the YOLOE detector + MobileCLIP text encoder have loaded.
    @Published private(set) var isReady = false
    /// True if the bundled models could not be loaded (e.g. not present in the build).
    @Published private(set) var loadFailed = false

    private var detector: TextGroundingDetector?

    /// Load the YOLOE detector, RepRTA, MobileCLIP text encoder, and the CLIP
    /// tokenizer from the bundled artifacts. Safe to call repeatedly (no-op once
    /// loaded). The detector loads its models in `init`, so it is created off the
    /// main thread; `isModelLoaded` then flips on the main queue.
    func loadIfNeeded() async {
        guard detector == nil else { return }
        let made = await Task.detached(priority: .userInitiated) { TextGroundingDetector() }.value
        detector = made
        // Wait briefly for the main-queue isModelLoaded flip (resolves in ms on
        // success; only a missing-models failure runs out the timeout).
        for _ in 0..<300 where !made.isModelLoaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        isReady = made.isModelLoaded
        loadFailed = !made.isModelLoaded
        if loadFailed { print("[TextGroundingProvider] YOLOE models failed to load") }
    }

    /// Boxes for each grounded query plus, optionally, the combined instance-mask
    /// overlay (proto-resolution RGBA, already de-letterboxed to the original image
    /// aspect). `maskImage` is nil when there were no detections.
    struct GroundingResult {
        let boxes: [Int: CGRect]
        let maskImage: CGImage?
    }

    /// Ground each query noun on the image and return one image-normalized
    /// (0...1, top-left) box per query that was found, keyed by the query's index
    /// in `queries` (its YOLOE `classIndex`). A query may yield zero, one, or many
    /// boxes; the highest-confidence box per query is kept. Missing queries are
    /// simply absent from the result. `maskImage` is the combined silhouette overlay
    /// reduced to one detection per class (matches the top-1-per-query box semantics).
    ///
    /// The default `confidenceThreshold` is intentionally low: the VLM has already
    /// confirmed that each query noun is in the frame, so we'd rather let a borderline
    /// box through and still pick the best one per query than miss the object entirely.
    ///
    /// Callers must pass non-empty queries: the detector drops empty ones, which would
    /// shift every later `classIndex` and misattribute boxes.
    func ground(cgImage: CGImage, queries: [String], confidenceThreshold: Float = 0.05) async -> GroundingResult {
        guard let detector, isReady, !queries.isEmpty else { return GroundingResult(boxes: [:], maskImage: nil) }
        // The detector splits the query string on commas, so a comma inside a query
        // would fragment it and shift every later classIndex; replace commas with
        // spaces to keep the join↔split 1:1 with `queries`.
        let queryString = queries.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ", ")
        let result: TextGroundingDetector.DetectionResult = await Task.detached(priority: .userInitiated) {
            detector.confidenceThreshold = confidenceThreshold
            detector.updateQueries(queryString)
            return detector.detectSyncWithMasks(image: UIImage(cgImage: cgImage), maskTopOnePerClass: true)
        }.value

        // classIndex == the index of the query in `queries`. Keep the top-confidence
        // box per query.
        var best: [Int: TextGroundingDetector.Detection] = [:]
        for detection in result.detections {
            if let current = best[detection.classIndex], current.confidence >= detection.confidence { continue }
            best[detection.classIndex] = detection
        }
        return GroundingResult(boxes: best.mapValues { $0.normRect }, maskImage: result.maskImage)
    }

    /// The single highest-confidence detection across all queries — Plate Reader's
    /// "top-1": the one most plate/meter/label-like region in the frame, to crop and
    /// read. Unlike `ground` (top-1 *per class*), this returns one box overall plus the
    /// query noun that matched (for the callout). Nil when nothing clears the
    /// (intentionally low) threshold.
    struct BestRegion {
        let box: CGRect      // image-normalized, top-left origin
        let label: String    // the query noun that matched (e.g. "nameplate")
    }

    func groundBest(cgImage: CGImage, queries: [String], confidenceThreshold: Float = 0.05) async -> BestRegion? {
        guard let detector, isReady, !queries.isEmpty else { return nil }
        // Same comma-safety as `ground`: the detector comma-splits the query string,
        // so a comma inside a query would shift every classIndex off its query.
        let queryString = queries.map { $0.replacingOccurrences(of: ",", with: " ") }.joined(separator: ", ")
        let result: TextGroundingDetector.DetectionResult = await Task.detached(priority: .userInitiated) {
            detector.confidenceThreshold = confidenceThreshold
            detector.updateQueries(queryString)
            return detector.detectSync(image: UIImage(cgImage: cgImage))
        }.value
        guard let best = result.detections.max(by: { $0.confidence < $1.confidence }) else { return nil }
        let label = queries.indices.contains(best.classIndex) ? queries[best.classIndex] : "object"
        return BestRegion(box: best.normRect, label: label)
    }
}
