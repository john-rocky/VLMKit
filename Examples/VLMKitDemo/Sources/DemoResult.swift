import CoreGraphics
import Foundation

/// The recipe-agnostic shape the demo shell renders. Each demo maps its own report
/// into this: a headline number, a list of labeled rows, and per-detection boxes.
/// Rows and detections are linked by `key`, so tapping one highlights the other —
/// VLMKit's "finger to point" payoff, kept independent of any single recipe.
struct DemoResult: Sendable {
    /// Optional overview pinned above the rows — ROI Zoom's whole-image pass. Nil for
    /// the count-style demos (α1/α2), which lead with the headline instead.
    let summary: String?
    let headline: Headline
    let rows: [AggregateRow]
    let detections: [Detection]

    init(summary: String? = nil, headline: Headline, rows: [AggregateRow], detections: [Detection]) {
        self.summary = summary
        self.headline = headline
        self.rows = rows
        self.detections = detections
    }

    struct Headline: Sendable {
        let value: Int
        let unit: String          // "items" / "people" / "regions"
    }
}

/// One row of the result list. `key` links it to its detection box(es).
struct AggregateRow: Identifiable, Sendable {
    let key: String
    let label: String             // primary text (product name / person summary)
    let trailing: String?         // short, right-aligned (α1: "×3")
    let subtitle: String?         // longer, wraps below (α2: the detailed description)
    var id: String { key }
}

/// One located thing on the photo. `key` links back to its row(s); `label` is the
/// callout shown when it is highlighted. `box` is image-normalized, top-left origin.
/// `page` is the 0-indexed page (multi-page Document QA only); nil means the
/// detection has no page concept and is shown regardless of the current page.
struct Detection: Identifiable, Sendable {
    let id: UUID
    let key: String
    let label: String           // short title shown in the callout
    let detail: String?         // longer body streamed into the callout (α2: the description)
    let box: CGRect
    let page: Int?

    // Explicit id so translation can rebuild a detection with the SAME identity
    // (a fresh UUID each render would restart the typewriter / break ForEach).
    init(id: UUID = UUID(), key: String, label: String, detail: String?, box: CGRect, page: Int? = nil) {
        self.id = id
        self.key = key
        self.label = label
        self.detail = detail
        self.box = box
        self.page = page
    }
}
