import SwiftUI
import Vision
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
    /// All captured pages for the current photo session — `[image]` for camera/photos,
    /// many for a multi-page scan (Document QA). Other demos read `.first`; Document QA
    /// uses the whole array. Empty = nothing captured yet.
    @Published private(set) var capturedPages: [UIImage] = []
    /// Which page the image area is currently showing. Document QA's page picker writes
    /// to this; single-image demos leave it at 0. Made settable so the picker can bind.
    @Published var currentPageIndex: Int = 0
    @Published private(set) var selectedDemo: Demo = .crowdAnalytics
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
    /// Combined YOLOE instance-mask overlay from the most recent Describe & Point run
    /// — drawn on the photo when the user toggles the mask outline on.
    @Published private(set) var describeMaskImage: CGImage?

    // Document QA: cached extraction + OCR-grounded boxes + answers for the current
    // scan. Re-asking a question reuses both passes instead of re-running them; an
    // identical question hits the answers cache for an instant response (no VLM
    // call). Keyed by the captured pages' identities so a new scan invalidates the
    // cache automatically.
    private var docCache: (
        pages: [UIImage],
        fields: [DocumentField],
        boxes: [Int: CGRect],
        answers: [String: DocumentAnswer]
    )?

    /// Receipt demo: the typed extraction surfaced separately from the generic
    /// `DemoResult` so the card view can render currency totals, items, and the
    /// CSV export buttons can read the same struct.
    @Published private(set) var receiptData: ReceiptData?
    /// Cache the extraction + the OCR-grounded detections so re-rendering or
    /// re-running on the same shot is free. Detections power the photo
    /// spotlight when a row is tapped. Keyed by `UIImage` identity, same
    /// scheme as `docCache`.
    private var receiptCache: (image: UIImage, data: ReceiptData, detections: [Detection])?

    /// Business Card demo: typed contact extraction surfaced separately from the
    /// generic `DemoResult` so the card view can render the contact fields and
    /// the "Save to Contacts" button can hand the struct to `CNContactViewController`.
    /// Cache also holds OCR-grounded detections so a row tap spotlights the
    /// value on the photo without re-running OCR.
    @Published private(set) var businessCardData: BusinessCardData?
    private var businessCardCache: (image: UIImage, data: BusinessCardData, detections: [Detection])?

    /// ID Document demo: typed KYC extraction + the holder's face crop (from
    /// `VNDetectFaceRectanglesRequest`) so the card can show a thumbnail. Face
    /// crop is best-effort — IDs without a recognizable face just render
    /// without the thumbnail. Cache also holds OCR-grounded detections + the
    /// face's normalized box (for the "tap holder → spotlight face" interaction).
    @Published private(set) var idDocumentData: IDDocumentData?
    @Published private(set) var idDocumentFace: CGImage?
    private var idDocumentCache: (
        image: UIImage,
        data: IDDocumentData,
        face: CGImage?,
        detections: [Detection]
    )?

    /// Listing demo: VLM-generated marketplace draft. Updated by both the
    /// initial pass (`analyzeListing`) and every subsequent `refineListing`
    /// call so the card view re-renders as the user iterates. True while a
    /// refinement VLM call is in flight — the refine TextField uses it to
    /// show a spinner instead of restarting the request.
    @Published private(set) var listingData: ListingData?
    @Published private(set) var isRefiningListing = false
    /// Background Studio output — when set, the photo area shows this composed
    /// "hero" image instead of the raw captured page. Cleared on new pages.
    @Published var listingHeroImage: UIImage?
    /// Cached initial draft so re-rendering / switching back to the demo on the
    /// same pages doesn't re-run the (~10 s) VLM pass. Keyed by the pages'
    /// identities, same scheme as `docCache`.
    private var listingCache: (pages: [UIImage], data: ListingData)?

    // Process-wide singleton backend/runner so AppIntents (Shortcuts / Siri) share
    // the same ~3 GB model load instead of paging in a second copy.
    private var backend: MLXSwiftBackend { SharedVLM.backend }
    private var runner: VLMRunner { SharedVLM.runner }

    /// Kick off the model load the moment the view model is created — i.e. at app
    /// launch, since the @StateObject autoclosure in ContentView fires on first body
    /// evaluation. This is preload: by the time the user picks a photo, the weights
    /// are (usually) already resident.
    ///
    /// If the first inference ever turns out to be materially slower than subsequent
    /// ones (kernel compile, KV-cache warmup, etc.), add a one-shot dry-run after the
    /// load completes here — a tiny prompt against a 1×1 placeholder image is enough
    /// to warm the pipeline. Skipped today because the current MLX path doesn't show
    /// a measurable first-call penalty on-device.
    init() {
        Task { await loadModelIfNeeded() }
    }

    var modelName: String { SharedVLM.modelName }
    var hasImage: Bool { !capturedPages.isEmpty }
    /// The page the image area should render. Driven by `currentPageIndex` so the
    /// Document QA page picker can flip pages without touching the underlying scan.
    var capturedImage: UIImage? {
        capturedPages.indices.contains(currentPageIndex)
            ? capturedPages[currentPageIndex]
            : capturedPages.first
    }
    var isBusy: Bool {
        switch phase {
        case .preparing, .downloading, .running: true
        default: false
        }
    }

    /// Load the model once (idempotent — `SharedVLM` guards against double loads
    /// across the app and any App Intent invocations). Maps the download fraction
    /// onto the `.downloading` phase so the UI shows the same progress bar it
    /// did before this was hoisted to a singleton.
    func loadModelIfNeeded() async {
        do {
            try await SharedVLM.loadIfNeeded { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(fraction) }
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
            if hasImage {
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

    /// Run the selected demo on freshly captured pages (one element for camera/photos,
    /// many for a multi-page scan). Resets the page picker to the first page and
    /// clears any per-demo derived state that's tied to the previous photo set.
    func analyze(_ pages: [UIImage], detail: Int, query: String) async {
        guard !pages.isEmpty else { return }
        capturedPages = pages
        currentPageIndex = 0
        // New photos → drop the previous Listing hero. The studio sheet would
        // otherwise render the wrong composite if the user re-opens it.
        listingHeroImage = nil
        if selectedDemo.isTapToAnalyze {
            await beginTapSession()
        } else {
            await analyzeCurrent(detail: detail, query: query)
        }
    }

    /// Displayed image for the top half. Listing demo shows the Background
    /// Studio hero composite when one has been chosen; everything else falls
    /// through to the page-picker-driven `capturedImage`.
    var displayedImage: UIImage? {
        if selectedDemo.id == Demo.listing.id, let hero = listingHeroImage {
            return hero
        }
        return capturedImage
    }

    /// (Re)run the selected demo on the current photo — e.g. after switching demos.
    func analyzeCurrent(detail: Int, query: String) async {
        if selectedDemo.id == Demo.describeAndPoint.id {   // run-once, but needs the grounding provider
            await analyzeDescribeAndPoint()
            return
        }
        if selectedDemo.id == Demo.plateReader.id {        // YOLOE crop → VLM structured read
            await analyzePlateReader(query: query)
            return
        }
        if selectedDemo.id == Demo.documentQA.id {         // two-call flow with per-photo cache
            await analyzeDocumentQA(query: query)
            return
        }
        if selectedDemo.id == Demo.receipt.id {            // schema-driven, holds typed ReceiptData
            await analyzeReceipt()
            return
        }
        if selectedDemo.id == Demo.businessCard.id {       // schema-driven, holds typed BusinessCardData
            await analyzeBusinessCard()
            return
        }
        if selectedDemo.id == Demo.idDocument.id {         // schema-driven + face crop
            await analyzeIDDocument()
            return
        }
        if selectedDemo.id == Demo.listing.id {            // generation + multi-turn refine
            await analyzeListing()
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
        describeMaskImage = nil
        await textGroundingProvider.loadIfNeeded()
        do {
            let description = try await DescribeAndPoint.run(on: vlmImage, runner: runner, maxObjects: 8)
            // Objects with a usable detector query, in caption order. The detector drops
            // empty queries, so filtering them here keeps each object's index equal to its
            // YOLOE classIndex (the key boxes come back under).
            let groundable = description.objects.filter {
                !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let grounding = await textGroundingProvider.ground(
                cgImage: vlmImage.cgImage, queries: groundable.map(\.query)
            )
            describeMaskImage = grounding.maskImage
            // A "mention" is an object YOLOE located; keep caption order, index is a stable key.
            var mentions: [(key: String, phrase: String, box: CGRect)] = []
            for (index, object) in groundable.enumerated() {
                guard let box = grounding.boxes[index] else { continue }
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

    // MARK: - Plate Reader

    /// Crop one object with YOLOE, then read it at high resolution. YOLOE finds the
    /// single most nameplate / meter / label-like region (top-1 across a built-in noun
    /// set); the VLM then reads a full-res crop of just that region — structured
    /// {label, value} fields by default (`DocumentQA.extract`), or a free-form answer
    /// when the user typed a prompt (`ROIZoom.detail`). Replaces the old MobileSAM tap
    /// ROI Zoom (SAM was unstable).
    ///
    /// The high-res win is ROI Zoom's: cropping the region from the original image
    /// before the backend's pixel-budget downscale spends the whole budget on the plate,
    /// so small stamped text and gauge markings stay legible.
    private func analyzePlateReader(query: String) async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        await textGroundingProvider.loadIfNeeded()
        // YOLOE picks the single most plate-like region. If nothing clears the (low)
        // threshold, fall back to reading the whole frame so the demo still produces a
        // result — no box is drawn in that case.
        let region = await textGroundingProvider.groundBest(
            cgImage: vlmImage.cgImage, queries: Self.plateQueries
        )
        // Pad the (tight) YOLOE box a little so stamped border text isn't clipped; show
        // the same padded box we read, so the overlay matches what the VLM saw.
        let roi = region.map { Self.paddedROI($0.box) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let detections: [Detection] = region.map {
            [Detection(key: "plate-region", label: $0.label.capitalized, detail: nil, box: roi)]
        } ?? []
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Default: autonomously identify the object and read it into structured
                // {label, value} fields. PlateReader (not DocumentQA) — plates stamp
                // values with no printed field name, so the value is required and the
                // label is inferred; `subject` is the VLM's own "what is this".
                let crop = vlmImage.cropped(to: roi)
                let reading = try await PlateReader.read(on: crop, runner: runner)
                let rows = reading.fields.enumerated().map { index, field in
                    AggregateRow(key: "plate-\(index)", label: field.label, trailing: nil, subtitle: field.value)
                }
                phase = .result(DemoResult(
                    summary: reading.subject.isEmpty ? nil : reading.subject,
                    headline: .init(value: reading.fields.count, unit: "fields"),
                    rows: rows,
                    detections: detections
                ))
            } else {
                // A typed prompt switches to a free-form answer about the cropped region.
                let answer = try await ROIZoom.detail(on: vlmImage, roi: roi, runner: runner, question: trimmed)
                phase = .result(DemoResult(
                    summary: "Q: \(trimmed)\nA: \(answer)",
                    headline: .init(value: 1, unit: "region"),
                    rows: [],
                    detections: detections
                ))
            }
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    /// The built-in YOLOE noun set Plate Reader searches for — plate / meter / label /
    /// gauge-like things. The single highest-confidence hit across all of them is the
    /// region cropped and read. Tuned for industrial nameplates, caution plates, rating
    /// plates, and gauges.
    private static let plateQueries = [
        "nameplate", "rating plate", "caution plate", "label", "sticker",
        "sign", "gauge", "meter", "display", "panel", "placard"
    ]

    /// Expand a tight YOLOE box by a small margin (clamped to the image) so stamped
    /// border text on a plate isn't clipped from the high-res crop.
    private static func paddedROI(_ box: CGRect, by fraction: CGFloat = 0.04) -> CGRect {
        box.insetBy(dx: -box.width * fraction, dy: -box.height * fraction)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Document QA

    /// Multi-page Document QA: per-page VLM extract (actor-serial through the same
    /// backend) runs in parallel with per-page Vision OCR (CPU, fan-out across cores).
    /// Fields are page-tagged so the page picker can filter detections and rows can
    /// show a `P{n}` chip. If the user typed a question, the answer is **streamed**
    /// character-by-character; the recipe asks the model to cite the page, and the
    /// shell auto-flips the page picker to that page when the answer lands.
    ///
    /// Caches per scan (keyed by the page UIImages' identities):
    /// - extract + OCR boxes → follow-up questions skip both passes
    /// - answered questions → an identical question on the same scan returns
    ///   instantly (no VLM call at all)
    private func analyzeDocumentQA(query: String) async {
        let uiPages = capturedPages
        guard !uiPages.isEmpty else {
            phase = .failed("Could not read the image.")
            return
        }
        let vlmPages = uiPages.compactMap { VLMImage(uiImage: $0.normalizedUp()) }
        guard vlmPages.count == uiPages.count else {
            phase = .failed("Could not read one of the pages.")
            return
        }
        let multiPage = uiPages.count > 1
        phase = .running(done: 0, total: 0)
        do {
            let fields: [DocumentField]
            let boxes: [Int: CGRect]
            if let cached = docCache,
               cached.pages.count == uiPages.count,
               zip(cached.pages, uiPages).allSatisfy({ $0 === $1 }) {
                fields = cached.fields
                boxes = cached.boxes
            } else {
                // Per-page VLM extract is actor-serial (one page at a time through
                // the same MLX backend); per-page Vision OCR fans out across CPU
                // cores. Run the two pipelines in parallel — OCR is essentially free
                // alongside the GPU extract chain.
                async let extractTask = DocumentQA.extract(on: vlmPages, runner: runner)
                let observations = await withTaskGroup(
                    of: (Int, [OCRObservation]).self,
                    returning: [OCRObservation].self
                ) { group in
                    for (pageIndex, vlmImage) in vlmPages.enumerated() {
                        group.addTask {
                            let raw = await OCRProvider.recognize(cgImage: vlmImage.cgImage)
                            return (pageIndex, raw.map {
                                OCRObservation(text: $0.text, box: $0.box, page: pageIndex)
                            })
                        }
                    }
                    var merged: [OCRObservation] = []
                    for await (_, pageObs) in group { merged.append(contentsOf: pageObs) }
                    return merged
                }
                let extraction = try await extractTask
                fields = extraction.fields
                boxes = DocumentQA.locate(fields: fields, in: observations)
                docCache = (uiPages, fields, boxes, [:])
            }

            // Detections get the page so the spotlight overlay can filter to the
            // currently-shown page; rows get a `P{n}` chip in their trailing slot.
            // Single-page docs leave both nil so the UI stays as before.
            let detections: [Detection] = fields.enumerated().compactMap { index, field in
                guard let box = boxes[index] else { return nil }
                return Detection(
                    key: "doc-\(index)",
                    label: field.label,
                    detail: field.value,
                    box: box,
                    page: multiPage ? field.page : nil
                )
            }
            let rows = fields.enumerated().map { index, field in
                AggregateRow(
                    key: "doc-\(index)",
                    label: field.label,
                    trailing: multiPage ? "P\(field.page + 1)" : nil,
                    subtitle: field.value
                )
            }
            let baseHeadline = DemoResult.Headline(value: fields.count, unit: "fields")

            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else {
                phase = .result(DemoResult(
                    summary: nil, headline: baseHeadline, rows: rows, detections: detections
                ))
                resultCount += 1
                return
            }

            // Answer cache hit: instant response, no VLM call.
            if let cached = docCache?.answers[trimmedQuery] {
                jumpToAnswerPage(cached)
                phase = .result(DemoResult(
                    summary: formatDocAnswer(question: trimmedQuery, answer: cached, multiPage: multiPage),
                    headline: baseHeadline, rows: rows, detections: detections
                ))
                resultCount += 1
                return
            }

            // Stream the answer: bump phase per chunk so the summary types itself
            // out as the model generates. resultCount is bumped only at the end so
            // the (relatively expensive) Apple-Translation pass runs once on the
            // final answer, not per chunk.
            let answer = try await DocumentQA.ask(
                trimmedQuery, on: vlmPages, runner: runner
            ) { [weak self] partial in
                Task { @MainActor in
                    guard let self else { return }
                    self.phase = .result(DemoResult(
                        summary: self.formatStreamingAnswer(question: trimmedQuery, partial: partial),
                        headline: baseHeadline, rows: rows, detections: detections
                    ))
                }
            }

            docCache?.answers[trimmedQuery] = answer
            jumpToAnswerPage(answer)
            phase = .result(DemoResult(
                summary: formatDocAnswer(question: trimmedQuery, answer: answer, multiPage: multiPage),
                headline: baseHeadline, rows: rows, detections: detections
            ))
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    /// Auto-flip the page picker to the page the model cited as evidence. Single-
    /// page docs and non-pinpointed answers leave it alone.
    private func jumpToAnswerPage(_ answer: DocumentAnswer) {
        guard let page = answer.page, capturedPages.indices.contains(page) else { return }
        currentPageIndex = page
    }

    /// Final summary for a Document QA answer — "Q / A" plus the optional verbatim
    /// evidence the model cited and, for multi-page docs, the cited page number.
    private func formatDocAnswer(question: String, answer: DocumentAnswer, multiPage: Bool = false) -> String {
        var lines = ["Q: \(question)", "A: \(answer.answer)"]
        if let evidence = answer.evidence { lines.append("— “\(evidence)”") }
        if multiPage, let page = answer.page { lines.append("(from page \(page + 1))") }
        return lines.joined(separator: "\n")
    }

    /// Live summary while the answer is still streaming. Trailing block cursor
    /// makes it read as "the model is still typing" rather than "this is the
    /// final answer".
    private func formatStreamingAnswer(question: String, partial: String) -> String {
        "Q: \(question)\nA: \(partial)▌"
    }

    // MARK: - Listing (Visual Listing Builder)

    /// First pass for the Listing demo: VLM reads every captured angle and
    /// writes a draft marketplace listing. Multi-photo (the user picks 1–5
    /// angles via PHPicker) so the VLM can synthesize across views. Cached on
    /// the pages array so re-rendering or returning to the demo is free.
    private func analyzeListing() async {
        let uiPages = capturedPages
        guard !uiPages.isEmpty else {
            phase = .failed("Could not read the image.")
            return
        }
        let vlmPages = uiPages.compactMap { VLMImage(uiImage: $0.normalizedUp()) }
        guard vlmPages.count == uiPages.count else {
            phase = .failed("Could not read one of the photos.")
            return
        }
        phase = .running(done: 0, total: 0)
        do {
            let data: ListingData
            if let cached = listingCache,
               cached.pages.count == uiPages.count,
               zip(cached.pages, uiPages).allSatisfy({ $0 === $1 }) {
                data = cached.data
            } else {
                data = try await Listing.generate(on: vlmPages, runner: runner)
                listingCache = (uiPages, data)
            }
            listingData = data
            phase = .result(DemoResult(
                summary: nil,
                headline: .init(value: data.features.count, unit: "features"),
                rows: [],
                detections: []
            ))
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    /// Multi-turn refinement: same images, a new instruction ("more casual",
    /// "translate to English", "shorter title"). Updates `listingData` in
    /// place so the card view re-renders. Keeps `phase = .result` so the busy
    /// indicator on the input field uses `isRefiningListing` instead of
    /// blanking the card.
    func refineListing(instruction: String) async {
        let uiPages = capturedPages
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let previous = listingData,
              !uiPages.isEmpty,
              !isRefiningListing else { return }
        let vlmPages = uiPages.compactMap { VLMImage(uiImage: $0.normalizedUp()) }
        guard vlmPages.count == uiPages.count else { return }
        isRefiningListing = true
        defer { isRefiningListing = false }
        do {
            let revised = try await Listing.refine(
                previous, on: vlmPages, instruction: trimmed, runner: runner
            )
            listingData = revised
            listingCache = (uiPages, revised)
            resultCount += 1
        } catch {
            // Keep the previous draft visible — refining failed, but the user
            // hasn't lost anything. Surfacing the error as a banner would be
            // nice; for now the spinner just disappears.
        }
    }

    // MARK: - ID Document

    /// VLM extract + Vision face detection + Vision OCR run in parallel (GPU
    /// vs CPU, no contention). Face thumbnail is best-effort — IDs without a
    /// recognizable face just render without the thumbnail. OCR grounds each
    /// extracted value (document number, holder name, dates, MRZ, …) so the
    /// photo spotlights the location when the user taps a row. Cached per
    /// photo.
    private func analyzeIDDocument() async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        do {
            let data: IDDocumentData
            let face: CGImage?
            let detections: [Detection]
            if let cached = idDocumentCache, cached.image === uiImage {
                data = cached.data
                face = cached.face
                detections = cached.detections
            } else {
                async let extractTask = IDDocument.extract(on: vlmImage, runner: runner)
                async let faceTask = Self.detectFace(in: vlmImage.cgImage)
                async let ocrTask = OCRProvider.recognize(cgImage: vlmImage.cgImage)
                let extracted = try await extractTask
                let faceResult = await faceTask
                let observations = await ocrTask
                data = extracted
                face = faceResult?.crop
                detections = SchemaGrounding.detections(
                    for: data,
                    observations: observations,
                    faceBox: faceResult?.box
                )
                idDocumentCache = (uiImage, data, face, detections)
            }
            idDocumentData = data
            idDocumentFace = face
            phase = .result(DemoResult(
                summary: nil,
                headline: .init(value: data.additionalFields.count, unit: "extra fields"),
                rows: [],
                detections: detections
            ))
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    /// Largest face on the page: returns its padded crop plus the unpadded
    /// box in image-normalized (0...1, top-left) coords so the spotlight
    /// overlay can highlight the face in place. Vision boxes are bottom-left;
    /// converted to top-left here. The crop is padded 15%/20% on the sides
    /// (hairline/chin); the returned `box` is the unpadded face rect — what
    /// the user expects when they tap "Holder" and the spotlight lands on
    /// the face proper, not on neck/hair around it.
    private static func detectFace(in cgImage: CGImage) async -> (crop: CGImage, box: CGRect)? {
        await Task.detached(priority: .userInitiated) {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            guard let face = (request.results ?? []).max(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }) else { return nil }
            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)
            let bb = face.boundingBox
            let normalizedBox = CGRect(
                x: bb.minX, y: 1 - bb.maxY,
                width: bb.width, height: bb.height
            )
            let pixel = CGRect(
                x: bb.minX * width,
                y: (1 - bb.maxY) * height,
                width: bb.width * width,
                height: bb.height * height
            )
            let padded = pixel.insetBy(
                dx: -pixel.width * 0.15,
                dy: -pixel.height * 0.20
            )
            let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
            let clamped = padded.intersection(imageBounds)
            guard clamped.width > 0, clamped.height > 0,
                  let crop = cgImage.cropping(to: clamped) else { return nil }
            return (crop, normalizedBox)
        }.value
    }

    // MARK: - Business Card

    /// One VLM call returns a typed `BusinessCardData` (name, company, title,
    /// phones, emails, URLs, address, socials) in parallel with a Vision OCR
    /// pass that grounds each value on the card. Surface on `businessCardData`
    /// for the bespoke card view; populate `DemoResult.detections` so the
    /// existing photo spotlight overlay highlights whichever row the user
    /// taps. Cached per photo.
    private func analyzeBusinessCard() async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        do {
            let data: BusinessCardData
            let detections: [Detection]
            if let cached = businessCardCache, cached.image === uiImage {
                data = cached.data
                detections = cached.detections
            } else {
                // OCR-grounded box overlay disabled per owner: Vision OCR misses
                // some characters and the box-on-text effect is uneven. The VLM
                // extracts/structures the card alone; no detections → no photo
                // overlay. Re-enable by restoring the parallel ocrTask + SchemaGrounding.
                let extracted = try await BusinessCard.extract(on: vlmImage, runner: runner)
                data = extracted
                detections = []
                businessCardCache = (uiImage, data, detections)
            }
            businessCardData = data
            let count = data.phones.count + data.emails.count + data.urls.count + data.socials.count
            phase = .result(DemoResult(
                summary: nil,
                headline: .init(value: count, unit: "contact methods"),
                rows: [],
                detections: detections
            ))
            resultCount += 1
        } catch {
            phase = .failed("Analysis failed: \(error)")
        }
    }

    // MARK: - Receipt

    /// One VLM call returns a typed `ReceiptData` (merchant, date, currency,
    /// totals, items, category) in parallel with a Vision-OCR pass that grounds
    /// each value on the page. Surface on `receiptData` for the bespoke card
    /// view; populate `DemoResult.detections` so the existing photo spotlight
    /// overlay highlights whichever row the user taps. Cached per photo.
    private func analyzeReceipt() async {
        guard let uiImage = capturedImage,
              let vlmImage = VLMImage(uiImage: uiImage.normalizedUp()) else {
            phase = .failed("Could not read the image.")
            return
        }
        phase = .running(done: 0, total: 0)
        do {
            let data: ReceiptData
            let detections: [Detection]
            if let cached = receiptCache, cached.image === uiImage {
                data = cached.data
                detections = cached.detections
            } else {
                // OCR-grounded box overlay disabled per owner: Vision OCR misses
                // some characters and the box-on-text effect is uneven. The VLM
                // extracts/structures the receipt alone; no detections → no
                // photo overlay. Re-enable by restoring the parallel ocrTask + SchemaGrounding.
                let extracted = try await Receipt.extract(on: vlmImage, runner: runner)
                data = extracted
                detections = []
                receiptCache = (uiImage, data, detections)
            }
            receiptData = data
            // The card view reads from `receiptData` directly; `detections`
            // drive the photo spotlight + auto-tour. `rows` stays empty so the
            // generic ResultView is not used (bespoke card takes over).
            phase = .result(DemoResult(
                summary: nil,
                headline: .init(value: data.items.count, unit: "items"),
                rows: [],
                detections: detections
            ))
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

}

extension UIImage {
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
