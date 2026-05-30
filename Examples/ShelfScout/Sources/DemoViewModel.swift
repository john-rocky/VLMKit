import SwiftUI
import VLMKit

/// Drives the multi-demo shell: loads the model once (shared across demos), runs the
/// selected demo on a captured image, and publishes progress/results. Switching
/// demos reuses the loaded model — no reload of the ~3 GB weights.
@MainActor
final class DemoViewModel: ObservableObject {
    enum Phase {
        case preparing
        case downloading(Double)
        case ready
        /// `total == 0` means the count isn't known yet (e.g. Vision hasn't run) —
        /// render an indeterminate spinner until the first progress callback.
        case running(done: Int, total: Int)
        case result(DemoResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var selectedDemo: Demo = .shelfInventory
    /// Bumps each time a new result is published — lets the view re-trigger translation.
    @Published private(set) var resultCount = 0

    let demos = Demo.all

    /// MobileSAM-backed region provider for tap-to-analyze demos (ROI Zoom). Loaded
    /// lazily the first time such a demo needs it.
    let samProvider = SAMROIProvider()
    /// True while a tap's segmentation is running — debounces taps and drives a spinner.
    @Published private(set) var isSegmenting = false
    /// True if MobileSAM could not load (models not bundled yet) — surfaced as a hint.
    @Published private(set) var roiUnavailable = false
    /// The whole-image overview text (ROI Zoom's stage 1), and whether it is still running.
    @Published private(set) var roiSummary: String?
    @Published private(set) var roiSummaryPending = false
    /// Count of in-flight high-res detail passes — drives the "analyzing" spinner.
    @Published private(set) var roiDetailInFlight = 0

    // Tap-to-analyze (ROI Zoom) state: the upright image SAM and the VLM see, plus the
    // regions accumulated so far. Held here so the shell stays recipe-agnostic.
    private var roiImage: VLMImage?
    private var roiDetections: [Detection] = []
    /// Bumped whenever the ROI session resets (new photo / demo switch) so a late VLM
    /// result from a previous session is dropped instead of polluting the current one.
    private var roiGeneration = 0

    /// YOLOE-backed open-vocab grounding for Describe & Point (the "point" half — the
    /// VLM names objects, this localizes them). Loaded lazily the first time it runs.
    let textGroundingProvider = TextGroundingProvider()

    // Default preset (~3 GB). Swap for `.smolVLM2` to test with a smaller, faster download.
    private let backend = MLXSwiftBackend(profile: .qwen3VL4B)
    private lazy var runner = VLMRunner(backend: backend)
    private var didStartLoading = false

    var modelName: String { backend.profile.displayName }
    var hasImage: Bool { capturedImage != nil }
    var isBusy: Bool {
        switch phase {
        case .preparing, .downloading, .running: true
        default: false
        }
    }

    /// Load the model once. Uses a model sideloaded via USB if present
    /// (`Documents/Model`); otherwise downloads the preset from Hugging Face.
    func loadModelIfNeeded() async {
        guard !didStartLoading else { return }
        didStartLoading = true
        do {
            if let local = Self.sideloadedModelDirectory() {
                try await backend.load(from: local)
            } else {
                try await backend.load { [weak self] fraction in
                    Task { @MainActor in self?.phase = .downloading(fraction) }
                }
            }
            phase = .ready
        } catch {
            phase = .failed("Model load failed: \(error)")
        }
    }

    /// Switch demos: keep the loaded model and the current photo, drop the old result.
    /// A tap-to-analyze demo with a photo already loaded enters tap mode right away.
    func select(_ demo: Demo) {
        guard !isBusy, demo.id != selectedDemo.id else { return }
        selectedDemo = demo
        resetROIState()
        if demo.isTapToAnalyze {
            if capturedImage != nil {
                Task { await beginTapSession() }
            } else {
                phase = .ready
            }
        } else {
            switch phase {
            case .result, .failed: phase = .ready
            default: break
            }
        }
    }

    /// Run the selected demo on a freshly captured image (or enter tap mode for a
    /// tap-to-analyze demo).
    func analyze(_ image: UIImage, detail: Int, query: String) async {
        capturedImage = image
        if selectedDemo.isTapToAnalyze {
            await beginTapSession()
        } else {
            await analyzeCurrent(detail: detail, query: query)
        }
    }

    /// (Re)run the selected demo on the current photo — e.g. after switching demos.
    func analyzeCurrent(detail: Int, query: String) async {
        if selectedDemo.id == Demo.describeAndPoint.id {   // run-once, but needs the grounding provider
            await analyzeDescribeAndPoint()
            return
        }
        guard let run = selectedDemo.run else { return }   // tap-to-analyze demos don't run once
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        do {
            let result = try await run(vlmImage, runner, detail, query) { [weak self] done, total in
                Task { @MainActor in self?.phase = .running(done: done, total: total) }
            }
            phase = .result(result)
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    // MARK: - Describe & Point

    /// The VLM writes a caption and names the concrete objects; YOLOE (app-side,
    /// off-main) boxes each one. A "mention" is an object YOLOE located; the caption (in
    /// `summary`) and the boxes share those objects in caption order, so the shell's
    /// existing tour + result⇄region highlighting walks them. (The synced in-caption word
    /// highlight is the next step; this reuses the shell as-is.)
    private func analyzeDescribeAndPoint() async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        await textGroundingProvider.loadIfNeeded()
        do {
            let description = try await DescribeAndPoint.run(on: vlmImage, runner: runner, maxObjects: 8)
            // Objects with a usable detector query, in caption order. The detector drops
            // empty queries, so filtering them here keeps each object's index equal to its
            // YOLOE classIndex (the key boxes come back under).
            let groundable = description.objects.filter {
                !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let boxes = await textGroundingProvider.ground(
                cgImage: vlmImage.cgImage, queries: groundable.map(\.query)
            )
            // A "mention" is an object YOLOE located; keep caption order, index is a stable key.
            var mentions: [(key: String, phrase: String, box: CGRect)] = []
            for (index, object) in groundable.enumerated() {
                guard let box = boxes[index] else { continue }
                mentions.append((key: "dp-\(index)", phrase: object.phrase, box: box))
            }
            let result = DemoResult(
                summary: description.caption,
                headline: .init(value: mentions.count, unit: "objects"),
                rows: mentions.map { AggregateRow(key: $0.key, label: $0.phrase, trailing: nil, subtitle: nil) },
                detections: mentions.map { Detection(key: $0.key, label: $0.phrase, detail: nil, box: $0.box) }
            )
            phase = .result(result)
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    // MARK: - Tap-to-analyze (ROI Zoom)

    /// Enter tap mode for the current photo: encode it for SAM, kick off the low-res
    /// overview pass, and show an (initially empty) result the user taps to add regions.
    func beginTapSession() async {
        resetROIState()
        let generation = roiGeneration
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        roiImage = vlmImage
        roiSummaryPending = true
        phase = .result(roiResult())
        resultCount += 1
        await samProvider.loadIfNeeded()
        roiUnavailable = samProvider.loadFailed
        await samProvider.setImage(vlmImage.cgImage)
        await runOverview(image: vlmImage, generation: generation)
    }

    /// Segment the object at a normalized (0...1, top-left) point and analyze it.
    func addROI(atNormalizedPoint point: CGPoint) async {
        guard let image = roiImage else { return }
        await segmentAndDetail(
            atImagePoint: CGPoint(x: point.x * CGFloat(image.width), y: point.y * CGFloat(image.height)),
            image: image
        )
    }

    /// Segment the object at the image center (the "Analyze center" button).
    func addROIAtCenter() async {
        guard let image = roiImage else { return }
        await segmentAndDetail(
            atImagePoint: CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2),
            image: image
        )
    }

    /// Stage 2: SAM localizes the region (fast — the box appears at once), then the VLM
    /// reads a high-res crop of just that region, streamed into the row + callout.
    private func segmentAndDetail(atImagePoint pixel: CGPoint, image: VLMImage) async {
        guard !isSegmenting else { return }
        let generation = roiGeneration
        isSegmenting = true
        let box = await samProvider.roi(atImagePoint: pixel)
        isSegmenting = false
        guard generation == roiGeneration, let box else { return }
        let index = roiDetections.count + 1
        let key = "roi-\(index)"
        roiDetections.append(Detection(key: key, label: "Region \(index)", detail: nil, box: box))
        phase = .result(roiResult())
        resultCount += 1
        await runDetail(forKey: key, roi: box, image: image, generation: generation)
    }

    /// Stage 1: the whole-image overview (low effective resolution) → the pinned summary.
    private func runOverview(image: VLMImage, generation: Int) async {
        let text = try? await ROIZoom.overview(on: image, runner: runner)
        guard generation == roiGeneration else { return }
        roiSummary = (text?.isEmpty == false) ? text : nil
        roiSummaryPending = false
        phase = .result(roiResult())
        resultCount += 1
    }

    /// The high-res detail pass for one region → fills its detail in place. The region
    /// keeps its `id`, so the callout typewriter and highlighting don't restart.
    private func runDetail(forKey key: String, roi: CGRect, image: VLMImage, generation: Int) async {
        roiDetailInFlight += 1
        let text = try? await ROIZoom.detail(on: image, roi: roi, runner: runner)
        if generation == roiGeneration { roiDetailInFlight -= 1 }
        guard generation == roiGeneration,
              let i = roiDetections.firstIndex(where: { $0.key == key }) else { return }
        let existing = roiDetections[i]
        roiDetections[i] = Detection(
            id: existing.id, key: existing.key, label: existing.label,
            detail: (text?.isEmpty == false) ? text : nil, box: existing.box
        )
        phase = .result(roiResult())
        resultCount += 1
    }

    /// The accumulated overview + regions as a `DemoResult` (one row + box per region).
    private func roiResult() -> DemoResult {
        DemoResult(
            summary: roiSummary,
            headline: .init(value: roiDetections.count, unit: "regions"),
            rows: roiDetections.map { AggregateRow(key: $0.key, label: $0.label, trailing: nil, subtitle: $0.detail) },
            detections: roiDetections
        )
    }

    /// Reset ROI session state and invalidate any in-flight VLM passes.
    private func resetROIState() {
        roiGeneration += 1
        roiDetections = []
        roiSummary = nil
        roiSummaryPending = false
        roiDetailInFlight = 0
    }

    /// A model folder sideloaded onto the device via USB into the app's Documents
    /// directory: `Documents/Model` containing the model's `config.json` and weights.
    /// Returns `nil` to fall back to the Hub download.
    private static func sideloadedModelDirectory() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("Model", isDirectory: true)
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) ? dir : nil
    }
}

private extension UIImage {
    /// Bake EXIF orientation into pixels — `VLMImage` reads the raw `CGImage`, so a
    /// camera photo must be uprighted before tiling or the VLM sees it rotated.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
