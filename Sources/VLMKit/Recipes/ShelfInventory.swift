import Foundation

public struct ShelfProduct: Codable, Sendable {
    public let name: String
    public let brand: String?
}

public struct ShelfItemCount: Codable, Sendable {
    public let name: String
    public let count: Int
}

public struct ShelfReport: Codable, Sendable {
    public let totalCount: Int
    public let items: [ShelfItemCount]
}

/// α1 — Shelf inventory. Tile the shelf (region-axis fan-out), list the products
/// visible in each tile, then aggregate counts by product name. Per-tile crops
/// give the VLM more effective resolution than a single downsampled pass, and
/// splitting the count across tiles sidesteps the VLM's weakness at counting
/// many objects in one shot.
public enum ShelfInventory {
    public static func pipeline(
        runner: VLMRunner,
        rows: Int = 3,
        columns: Int = 3
    ) -> FanoutPipeline<[ShelfProduct], ShelfReport> {
        FanoutPipeline(
            extractor: GridExtractor(rows: rows, columns: columns, overlap: 0.1),
            runner: runner,
            makeTask: { _ in
                VLMTask(
                    instruction: """
                    You are auditing a single tile cropped from a retail shelf photo. \
                    List every distinct product package clearly visible in this tile. \
                    Give each product's name and its brand if legible. Ignore products \
                    that are cut off at the edge or unreadable.
                    """,
                    jsonHint: #"[{"name": "string", "brand": "string or null"}]"#,
                    options: GenerationOptions(maxTokens: 512, temperature: 0.0)
                )
            },
            aggregator: ShelfCountAggregator()
        )
    }

    public static func run(
        on image: VLMImage,
        runner: VLMRunner,
        rows: Int = 3,
        columns: Int = 3,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> ShelfReport {
        try await pipeline(runner: runner, rows: rows, columns: columns)
            .run(on: image, onProgress: onProgress)
    }
}

/// Counts products by case-insensitive name while keeping a display name.
struct ShelfCountAggregator: Aggregator {
    func callAsFunction(_ inputs: [RegionResult<[ShelfProduct]>]) -> ShelfReport {
        var counts: [String: (display: String, count: Int)] = [:]
        for region in inputs {
            for product in region.output {
                let key = product.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                counts[key, default: (product.name, 0)].count += 1
            }
        }
        let items = counts.values
            .map { ShelfItemCount(name: $0.display, count: $0.count) }
            .sorted { $0.count > $1.count }
        return ShelfReport(totalCount: items.reduce(0) { $0 + $1.count }, items: items)
    }
}
