import XCTest
@testable import VLMKit

final class AggregatorTests: XCTestCase {
    func testListAggregatorFlattens() {
        let result = ListAggregator<Int>()([makeRegionResult([1, 2]), makeRegionResult([3])])
        XCTAssertEqual(result, [1, 2, 3])
    }

    func testCountAggregatorCountsAndSorts() {
        let aggregator = CountAggregator<String, String> { $0 }
        let result = aggregator([makeRegionResult(["a", "b", "a"]), makeRegionResult(["a"])])
        XCTAssertEqual(result.first?.value, "a")
        XCTAssertEqual(result.first?.count, 3)
    }

    func testShelfCountAggregatorMergesCaseInsensitively() {
        let result = ShelfCountAggregator()([
            makeRegionResult([ShelfProduct(name: "Coke", brand: nil, bbox2d: nil), ShelfProduct(name: "coke", brand: "Coca-Cola", bbox2d: nil)]),
            makeRegionResult([ShelfProduct(name: "Pepsi", brand: nil, bbox2d: nil)]),
        ])
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(result.items.first?.name, "Coke")
        XCTAssertEqual(result.items.first?.count, 2)
    }
}
