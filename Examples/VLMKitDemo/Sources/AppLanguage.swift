import Foundation

/// UI language. The VLM is always prompted in English; Japanese is produced with
/// Apple's Translation framework — the user's question is translated to English on
/// the way in, and the model's answer back to Japanese on the way out.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english
    case japanese

    var id: String { rawValue }
    var label: String { self == .english ? "English" : "日本語" }
    var needsTranslation: Bool { self == .japanese }
}

/// The user-visible strings in a result that should be translated for display.
/// Keys, counts (`trailing`), and boxes are deliberately left untouched.
func translatableStrings(in result: DemoResult) -> [String] {
    var seen = Set<String>()
    seen.insert(result.headline.unit)
    if let summary = result.summary { seen.insert(summary) }
    for row in result.rows {
        seen.insert(row.label)
        if let subtitle = row.subtitle { seen.insert(subtitle) }
    }
    for detection in result.detections {
        seen.insert(detection.label)
        if let detail = detection.detail { seen.insert(detail) }
    }
    return seen.filter { !$0.isEmpty }
}

/// Rewrite a result's display strings through a translation cache (English →
/// target). Missing entries fall back to the original, so the UI shows English
/// until translation lands. Identity (`key`, detection `id`), counts, and boxes are
/// preserved so highlighting and the typewriter stay stable.
func localized(_ result: DemoResult, using cache: [String: String]) -> DemoResult {
    func tr(_ string: String) -> String { cache[string] ?? string }
    return DemoResult(
        summary: result.summary.map(tr),
        headline: .init(value: result.headline.value, unit: tr(result.headline.unit)),
        rows: result.rows.map {
            AggregateRow(key: $0.key, label: tr($0.label), trailing: $0.trailing, subtitle: $0.subtitle.map(tr))
        },
        detections: result.detections.map {
            Detection(id: $0.id, key: $0.key, label: tr($0.label), detail: $0.detail.map(tr), box: $0.box, page: $0.page)
        }
    )
}
