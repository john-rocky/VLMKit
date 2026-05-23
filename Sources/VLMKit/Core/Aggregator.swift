/// Combine per-region (or per-call) results into a final output. The reduce
/// half of VLMKit's map-reduce. Concrete aggregators below cover the Phase-1
/// recipes; Table/Spatial/Temporal/Diff aggregators arrive with their genres.
public protocol Aggregator<Input, Output>: Sendable {
    associatedtype Input
    associatedtype Output
    func callAsFunction(_ inputs: [Input]) throws -> Output
}

/// Flatten per-region lists into one list (e.g. all items seen across tiles).
public struct ListAggregator<Item: Sendable>: Aggregator {
    public init() {}
    public func callAsFunction(_ inputs: [RegionResult<[Item]>]) -> [Item] {
        inputs.flatMap(\.output)
    }
}

public struct CountedItem<Key: Hashable & Codable & Sendable>: Codable, Sendable {
    public let value: Key
    public let count: Int
    public init(value: Key, count: Int) {
        self.value = value
        self.count = count
    }
}

/// Count occurrences of a key across all per-region items, most frequent first.
public struct CountAggregator<Item: Sendable, Key: Hashable & Codable & Sendable>: Aggregator {
    private let key: @Sendable (Item) -> Key

    public init(by key: @escaping @Sendable (Item) -> Key) {
        self.key = key
    }

    public func callAsFunction(_ inputs: [RegionResult<[Item]>]) -> [CountedItem<Key>] {
        var counts: [Key: Int] = [:]
        for region in inputs {
            for item in region.output {
                counts[key(item), default: 0] += 1
            }
        }
        return counts
            .map { CountedItem(value: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}
