import CoreGraphics
import XCTest
@testable import VLMKit

final class GridExtractorTests: XCTestCase {
    func testTileCount() {
        let regions = GridExtractor(rows: 3, columns: 4).extractRegions(from: makeTestImage())
        XCTAssertEqual(regions.count, 12)
    }

    func testExactTilingCoversUnitArea() {
        let regions = GridExtractor(rows: 2, columns: 2).extractRegions(from: makeTestImage())
        let area = regions.reduce(0) { $0 + $1.boundingBox.width * $1.boundingBox.height }
        XCTAssertEqual(area, 1.0, accuracy: 0.0001)
    }

    func testOverlapStaysInsideUnitSquare() {
        let regions = GridExtractor(rows: 3, columns: 3, overlap: 0.25).extractRegions(from: makeTestImage())
        for region in regions {
            let box = region.boundingBox
            XCTAssertGreaterThanOrEqual(box.minX, 0)
            XCTAssertGreaterThanOrEqual(box.minY, 0)
            XCTAssertLessThanOrEqual(box.maxX, 1.0 + 1e-6)
            XCTAssertLessThanOrEqual(box.maxY, 1.0 + 1e-6)
        }
    }

    func testCropProducesExpectedPixelSize() {
        let image = makeTestImage(width: 100, height: 100)
        let crop = image.cropped(to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.width, 50)
        XCTAssertEqual(crop.height, 50)
    }
}
