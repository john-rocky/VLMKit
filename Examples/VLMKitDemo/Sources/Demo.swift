import VLMKit

/// A demo the shell can run: a display name, the recipe call (returning the shared
/// `DemoResult`), and optional inputs it exposes — a grid-detail stepper and/or a
/// free-text question. The whole shell is built against this; adding a recipe is
/// adding a `Demo`, with no shell changes.
struct Demo: Identifiable, Sendable {
    let id: String
    let name: String
    /// Range for the "Detail: N×N tiles" stepper, or nil if the demo has no grid knob.
    let gridDetail: ClosedRange<Int>?
    /// Placeholder for a free-text question asked per detection, or nil if the demo
    /// takes none. Empty input falls back to the recipe's default prompt.
    let queryPlaceholder: String?
    /// Tap-to-analyze demos don't run once over the whole image; instead the user taps
    /// objects and each tap produces a region (ROI Zoom). Such demos have no `run`.
    let isTapToAnalyze: Bool
    /// The run-once recipe call, or nil for tap-to-analyze demos.
    let run: (@Sendable (
        _ image: VLMImage,
        _ runner: VLMRunner,
        _ detail: Int,
        _ query: String,
        _ onProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> DemoResult)?

    // `.shelfInventory` (α1, 9-tile fan-out) is disabled in the demo lineup: the
    // enumerate-by-tile pattern fights VLM weaknesses (counting many objects, tile-border
    // dedup) and modern VLMs already do their own internal tiling. The recipe itself is
    // kept around (see the `.shelfInventory` extension below) until we redesign it
    // around a single VLM call that plays to the model's qualitative strengths.
    // Demos kept in code but excluded from the menu (uncomment to restore):
    //  - `.roiZoom` / `.idDocument`: owner — "weak impact." ROI Zoom's MobileSAM
    //    (SAMKit) dep is now optional via `#if canImport(SAMKit)`, so the build
    //    works without it.
    // Receipt + BusinessCard: Vision OCR grounding (box-on-text overlay) is
    // disabled because OCR misses some characters; those demos now use VLM
    // alone for extraction, with no detection boxes on the photo. DocumentQA
    // keeps its OCR HUD (multi-page docs benefit from the spotlight more).
    static let all: [Demo] = [/* .shelfInventory, */ .crowdAnalytics, /* .roiZoom, */ .describeAndPoint, .documentQA, .receipt, .businessCard, /* .idDocument, */ /* .listing — Background Studio shelved; pure listing draft alone wasn't a strong enough demo */ .arMeasure]
}

extension Demo {
    /// α1 — tile the image (grid fan-out) and count products per tile.
    static let shelfInventory = Demo(
        id: "shelf",
        name: "Shelf Inventory",
        gridDetail: 2...4,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: { image, runner, detail, _, onProgress in
            try await ShelfInventory.run(
                on: image, runner: runner, rows: detail, columns: detail, onProgress: onProgress
            ).asDemoResult()
        }
    )

    /// α2 — Vision detects each person, the VLM answers a question about each one
    /// (or profiles them when no question is given). No grid knob; Vision decides the
    /// region count.
    static let crowdAnalytics = Demo(
        id: "crowd",
        name: "Crowd Analytics",
        gridDetail: nil,
        queryPlaceholder: "Ask about each person (e.g. Is this person wearing a hard hat?)",
        isTapToAnalyze: false,
        run: { image, runner, _, query, onProgress in
            try await CrowdAnalytics.run(
                on: image, runner: runner,
                question: query.isEmpty ? nil : query,
                onProgress: onProgress
            ).asDemoResult()
        }
    )

    /// P5 — ROI Zoom. A whole-image overview, then tap an object: MobileSAM (Apple
    /// on-device) localizes it, and the VLM reads a high-res crop of just that region.
    /// Tap-to-analyze, so it has no run-once pass; the shell drives it via the SAM
    /// provider. (Step 2: SAM tap → box. The VLM overview/detail passes land in step 3.)
    static let roiZoom = Demo(
        id: "roi",
        name: "ROI Zoom",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: true,
        run: nil
    )

    /// "Describe & Point" — the VLM writes a short caption and names the concrete
    /// objects in it; YOLOE (Apple-framework open-vocab detection, app-side) boxes each
    /// named object, in caption order. Run-once, but it needs the grounding provider, so
    /// — like ROI Zoom — the shell drives it through the view model, not this generic
    /// `run` closure (which has no provider).
    static let describeAndPoint = Demo(
        id: "describe",
        name: "Describe & Point",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )

    /// "Document QA" — auto-extract every labeled value off the document (machine
    /// plate, invoice, receipt, business card, form, …), then optionally answer a
    /// free-form question about it ("What is the frame number?"). The extracted
    /// fields are cached per photo, so re-asking is fast (one VLM call, not two).
    /// Driven through the view model (caching + two-call flow), so `run` is nil.
    static let documentQA = Demo(
        id: "doc",
        name: "Document QA",
        gridDetail: nil,
        queryPlaceholder: "Ask about the document (e.g. What is the frame number?)",
        isTapToAnalyze: false,
        run: nil
    )

    /// "Receipt" — schema-driven receipt extraction: one VLM call returns
    /// {merchant, date, currency, total, subtotal, tax, paymentMethod, category,
    /// items[]} as typed values you can sum, sort, and export as a CSV row.
    /// On-device only; no FinanceKit (Apple restricts that entitlement to
    /// banking apps). Driven through the view model so `run` is nil.
    static let receipt = Demo(
        id: "receipt",
        name: "Receipt",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )

    /// "Business Card" — VLM reads a card (name, company, title, phones,
    /// emails, URLs, address, socials), then the app drops the result into a
    /// `CNContactViewController` preview so the user confirms before saving to
    /// Apple Contacts. AppIntents-callable as well, returning a vCard string.
    static let businessCard = Demo(
        id: "card",
        name: "Business Card",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )

    /// "ID" — passport / driver's license / national ID extraction with face
    /// detection. Schema-driven KYC fields (doc type, name, doc#, DOB, sex,
    /// nationality, issue/expiry, address, MRZ). On-device only — the killer
    /// feature for regulated industries (fintech, healthcare). AppIntents-
    /// callable as well, returning a JSON string for chaining.
    static let idDocument = Demo(
        id: "id",
        name: "ID",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )

    /// "Listing" — Mercari / eBay-style marketplace listing builder. VLM reads
    /// multiple photos of one item and writes a draft listing (title /
    /// description / features / condition / suggested price range / tags /
    /// alt-text). The user can refine via a natural-language instruction
    /// ("make it more casual", "translate to English") and the VLM regenerates
    /// keeping what works. Generation, not extraction — the breakthrough
    /// pattern in this app.
    static let listing = Demo(
        id: "listing",
        name: "Listing",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )

    /// ε2 — AR + LiDAR object measurement (ported from the standalone
    /// ProductMeasure app the owner authored). Selecting this demo presents the
    /// AR measurement view full-screen instead of the photo→result shell: the
    /// user scans an object, then VLMKit describes it alongside W/H/L/Volume in
    /// the dimension callout. Has no `run` — the shell flips into full-screen
    /// AR mode via `isFullScreenAR`.
    static let arMeasure = Demo(
        id: "measure",
        name: "AR Measure",
        gridDetail: nil,
        queryPlaceholder: nil,
        isTapToAnalyze: false,
        run: nil
    )
}

// MARK: - Report → DemoResult adapters (presentation only; geometry stays in the recipes).

private extension ShelfReport {
    func asDemoResult() -> DemoResult {
        DemoResult(
            headline: .init(value: totalCount, unit: "items"),
            rows: items.map { AggregateRow(key: $0.name, label: $0.name, trailing: "×\($0.count)", subtitle: nil) },
            detections: detections.map { Detection(key: $0.name, label: $0.name, detail: nil, box: $0.box) }
        )
    }
}

private extension CrowdReport {
    func asDemoResult() -> DemoResult {
        DemoResult(
            headline: .init(value: totalPeople, unit: "people"),
            rows: people.map { AggregateRow(key: $0.id, label: $0.summary, trailing: nil, subtitle: $0.description) },
            detections: people.map { Detection(key: $0.id, label: $0.summary, detail: $0.description, box: $0.box) }
        )
    }
}

extension Demo {
    /// True for demos whose UX is a full-screen AR experience rather than the
    /// photo→result shell (currently just AR Measure). The shell presents these
    /// as a `fullScreenCover` and skips its normal capture/result chrome.
    var isFullScreenAR: Bool {
        id == Demo.arMeasure.id
    }
}

extension Demo {
    /// True for demos whose input is a printed sheet (Document QA, Receipt,
    /// Business Card, ID). The camera button swaps to Apple's document scanner
    /// (perspective correction at capture); the Photos picker runs the same
    /// correction on the picked still image via `DocumentRectifier`.
    var usesDocumentScanner: Bool {
        id == Demo.documentQA.id
            || id == Demo.receipt.id
            || id == Demo.businessCard.id
            || id == Demo.idDocument.id
    }
}
