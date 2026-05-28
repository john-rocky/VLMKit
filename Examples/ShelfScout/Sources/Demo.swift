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
    let run: @Sendable (
        _ image: VLMImage,
        _ runner: VLMRunner,
        _ detail: Int,
        _ query: String,
        _ onProgress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async throws -> DemoResult

    static let all: [Demo] = [.shelfInventory, .crowdAnalytics]
}

extension Demo {
    /// α1 — tile the image (grid fan-out) and count products per tile.
    static let shelfInventory = Demo(
        id: "shelf",
        name: "Shelf Inventory",
        gridDetail: 2...4,
        queryPlaceholder: nil,
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
        run: { image, runner, _, query, onProgress in
            try await CrowdAnalytics.run(
                on: image, runner: runner,
                question: query.isEmpty ? nil : query,
                onProgress: onProgress
            ).asDemoResult()
        }
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
