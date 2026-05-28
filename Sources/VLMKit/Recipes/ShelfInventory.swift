import CoreGraphics
import Foundation

public struct ShelfProduct: Codable, Sendable {
    public let name: String
    public let brand: String?
    /// Bounding box as the VLM returns it: `[x1, y1, x2, y2]` in 0...1000,
    /// normalized to the *tile* it was detected in. `nil` if not reported.
    public let bbox2d: [Double]?

    enum CodingKeys: String, CodingKey {
        case name, brand
        case bbox2d = "bbox_2d"
    }
}

public struct ShelfItemCount: Codable, Sendable {
    public let name: String
    public let count: Int
}

/// A single located product: name/brand plus an image-normalized bounding box
/// (top-left origin, 0...1) so the UI can highlight it on the photo.
public struct ShelfDetection: Codable, Sendable {
    public let name: String
    public let brand: String?
    public let box: CGRect

    public init(name: String, brand: String?, box: CGRect) {
        self.name = name
        self.brand = brand
        self.box = box
    }
}

public struct ShelfReport: Codable, Sendable {
    public let totalCount: Int
    public let items: [ShelfItemCount]
    /// Per-product boxes (image-normalized) for region highlighting.
    public let detections: [ShelfDetection]
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
                    Detect every distinct product package clearly visible in this tile. \
                    For each, give its name, its brand if legible, and its bounding box. \
                    Ignore products cut off at the edge or unreadable.
                    """,
                    jsonHint: #"[{"name": "string", "brand": "string or null", "bbox_2d": [x1, y1, x2, y2]}]"#,
                    options: GenerationOptions(maxTokens: 768, temperature: 0.0)
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
        var detections: [ShelfDetection] = []
        for region in inputs {
            let tile = region.region.boundingBox
            for product in region.output {
                let key = product.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                counts[key, default: (product.name, 0)].count += 1
                if let box = Self.imageBox(product.bbox2d, in: tile) {
                    detections.append(ShelfDetection(name: product.name, brand: product.brand, box: box))
                }
            }
        }
        let items = counts.values
            .map { ShelfItemCount(name: $0.display, count: $0.count) }
            .sorted { $0.count > $1.count }
        return ShelfReport(
            totalCount: items.reduce(0) { $0 + $1.count },
            items: items,
            detections: detections
        )
    }

    /// Map a VLM `bbox_2d` (0...1000 within the tile) to an image-normalized rect,
    /// using the tile's own image-normalized rect to place it in the full image.
    private static func imageBox(_ bbox2d: [Double]?, in tile: CGRect) -> CGRect? {
        guard let b = bbox2d, b.count == 4 else { return nil }
        let x1 = min(b[0], b[2]) / 1000, x2 = max(b[0], b[2]) / 1000
        let y1 = min(b[1], b[3]) / 1000, y2 = max(b[1], b[3]) / 1000
        return CGRect(
            x: tile.minX + x1 * tile.width,
            y: tile.minY + y1 * tile.height,
            width: (x2 - x1) * tile.width,
            height: (y2 - y1) * tile.height
        )
    }
}
