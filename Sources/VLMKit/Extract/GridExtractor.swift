import CoreGraphics

/// Decompose the image into a `rows × columns` grid of tiles. Robust default for
/// dense scenes (shelves, panoramas) where per-tile crops give the VLM a higher
/// effective resolution than one downsampled full-image pass.
public struct GridExtractor: RegionExtractor {
    public let rows: Int
    public let columns: Int
    /// Fraction of a tile to extend on each side, so objects on tile borders are
    /// not split. `0` = exact tiling.
    public let overlap: CGFloat

    public init(rows: Int, columns: Int, overlap: CGFloat = 0) {
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.overlap = max(0, overlap)
    }

    public func extractRegions(from image: VLMImage) -> [Region] {
        let tileWidth = 1.0 / CGFloat(columns)
        let tileHeight = 1.0 / CGFloat(rows)
        var regions: [Region] = []
        regions.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = CGRect(
                    x: CGFloat(column) * tileWidth - overlap * tileWidth,
                    y: CGFloat(row) * tileHeight - overlap * tileHeight,
                    width: tileWidth * (1 + 2 * overlap),
                    height: tileHeight * (1 + 2 * overlap)
                ).clampedToUnitSquare()
                regions.append(Region(boundingBox: rect, label: "tile r\(row)c\(column)"))
            }
        }
        return regions
    }
}
