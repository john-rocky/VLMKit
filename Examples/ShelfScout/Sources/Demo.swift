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

    static let all: [Demo] = [.shelfInventory, .crowdAnalytics, .roiZoom, .describeAndPoint]
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
