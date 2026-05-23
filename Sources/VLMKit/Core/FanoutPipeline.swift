/// A region paired with the typed result the VLM produced for it.
public struct RegionResult<Output: Sendable>: Sendable {
    public let region: Region
    public let output: Output
    public init(region: Region, output: Output) {
        self.region = region
        self.output = output
    }
}

/// The region-axis fan-out, composed end to end:
/// `extractor → (crop + VLM task per region) → aggregator`.
///
/// This is the user-facing realization of VLMKit's root principle — one logical
/// VLM query decomposed into N spatially-anchored calls, then reduced. Calls run
/// sequentially through the backend (one GPU model); a region that fails after
/// retries is skipped and reported via `onError`.
public struct FanoutPipeline<RegionOutput: Decodable & Sendable, Final: Sendable>: Sendable {
    public let extractor: any RegionExtractor
    public let runner: VLMRunner
    public let makeTask: @Sendable (Region) -> VLMTask<RegionOutput>
    public let aggregator: any Aggregator<RegionResult<RegionOutput>, Final>

    public init(
        extractor: any RegionExtractor,
        runner: VLMRunner,
        makeTask: @escaping @Sendable (Region) -> VLMTask<RegionOutput>,
        aggregator: any Aggregator<RegionResult<RegionOutput>, Final>
    ) {
        self.extractor = extractor
        self.runner = runner
        self.makeTask = makeTask
        self.aggregator = aggregator
    }

    public func run(
        on image: VLMImage,
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil,
        onError: (@Sendable (Region, any Error) -> Void)? = nil
    ) async throws -> Final {
        let regions = try await extractor.extractRegions(from: image)
        var results: [RegionResult<RegionOutput>] = []
        results.reserveCapacity(regions.count)
        for (index, region) in regions.enumerated() {
            let crop = image.cropped(to: region.boundingBox)
            do {
                let output = try await runner.run(makeTask(region), images: [crop])
                results.append(RegionResult(region: region, output: output))
            } catch {
                onError?(region, error)
            }
            onProgress?(index + 1, regions.count)
        }
        return try aggregator(results)
    }
}
