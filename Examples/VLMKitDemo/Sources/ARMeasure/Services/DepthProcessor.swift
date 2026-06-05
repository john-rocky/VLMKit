//
//  DepthProcessor.swift
//  SnapMeasure
//

import ARKit
import simd

/// Processes depth data from ARKit LiDAR
class DepthProcessor {
    // MARK: - Types

    struct DepthData {
        /// Depth value in meters
        let depth: Float

        /// Confidence level (0-2, higher is better)
        let confidence: ARConfidenceLevel

        /// Pixel coordinates in depth map
        let pixelX: Int
        let pixelY: Int
    }

    struct DepthStats {
        let validPixels: Int
        let totalPixels: Int
        let averageConfidence: Float
        let minDepth: Float
        let maxDepth: Float

        var coverage: Float {
            Float(validPixels) / Float(max(totalPixels, 1))
        }
    }

    // MARK: - Public Methods

    /// Extract depth values for masked pixels
    /// - Parameters:
    ///   - frame: ARFrame containing depth data
    ///   - maskedPixels: Pixels in the segmentation mask (in image coordinates)
    ///   - imageSize: Size of the camera image
    ///   - depthSource: Depth source abstraction (LiDAR or ML)
    /// - Returns: Array of depth data for valid pixels
    func extractDepthForMask(
        frame: ARFrame,
        maskedPixels: [(x: Int, y: Int)],
        imageSize: CGSize,
        depthSource: DepthSource? = nil
    ) -> [DepthData] {
        let depthMap: CVPixelBuffer?
        let confidenceMap: CVPixelBuffer?
        let hasConfidence: Bool

        if let source = depthSource {
            depthMap = source.depthMap(for: frame)
            confidenceMap = source.confidenceMap(for: frame)
            hasConfidence = source.hasConfidenceMap
        } else {
            depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
            confidenceMap = frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap
            hasConfidence = true
        }

        guard let depthMap else {
#if DEBUG
            print("[Depth] No depth map available")
#endif
            return []
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

#if DEBUG
        print("[Depth] Depth map size: \(depthWidth)x\(depthHeight)")
        print("[Depth] Image size: \(imageSize)")
#endif

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return []
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

#if DEBUG
        print("[Depth] Depth bytes per row: \(depthBytesPerRow) (elements per row: \(depthBytesPerRow / 4))")
#endif

        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        // Confidence map pointers (optional)
        let confPtr: UnsafeMutablePointer<UInt8>?
        let confBytesPerRow: Int
        if hasConfidence, let confidenceMap,
           let confBase = CVPixelBufferGetBaseAddress(confidenceMap) {
            confPtr = confBase.assumingMemoryBound(to: UInt8.self)
            confBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        } else {
            confPtr = nil
            confBytesPerRow = 0
        }

        // Scale factors from image to depth coordinates
        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

#if DEBUG
        print("[Depth] Scale factors (image to depth): \(scaleX), \(scaleY)")
#endif

        var results: [DepthData] = []
#if DEBUG
        var debugCount = 0
#endif
        var rejectedCount = 0

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)

            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }

            let depthIndex = depthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + depthX
            let depth = depthPtr[depthIndex]

            let confidence: ARConfidenceLevel
            if let confPtr {
                let confIndex = depthY * confBytesPerRow + depthX
                let confValue = confPtr[confIndex]
                confidence = ARConfidenceLevel(rawValue: Int(confValue)) ?? .low
            } else {
                // ML depth: no confidence, treat as medium
                confidence = .medium
            }

#if DEBUG
            if debugCount < 5 {
                print("[Depth] Sample \(debugCount): imagePx=(\(pixel.x),\(pixel.y)) -> depthPx=(\(depthX),\(depthY)), depth=\(depth)m, conf=\(confidence.rawValue)")
                debugCount += 1
            }
#endif

            let minConfidence = hasConfidence ? ARConfidenceLevel.medium.rawValue : 0
            if depth.isFinite && depth > 0 && confidence.rawValue >= minConfidence {
                results.append(DepthData(
                    depth: depth,
                    confidence: confidence,
                    pixelX: depthX,
                    pixelY: depthY
                ))
            } else {
                rejectedCount += 1
            }
        }

#if DEBUG
        print("[Depth] Accepted: \(results.count), Rejected: \(rejectedCount)")
#endif

        return results
    }

    /// Get depth statistics for a region
    func getDepthStats(depthData: [DepthData]) -> DepthStats {
        guard !depthData.isEmpty else {
            return DepthStats(
                validPixels: 0,
                totalPixels: 0,
                averageConfidence: 0,
                minDepth: 0,
                maxDepth: 0
            )
        }

        var totalConfidence: Float = 0
        var minDepth: Float = .infinity
        var maxDepth: Float = -.infinity

        for data in depthData {
            totalConfidence += Float(data.confidence.rawValue)
            minDepth = min(minDepth, data.depth)
            maxDepth = max(maxDepth, data.depth)
        }

        return DepthStats(
            validPixels: depthData.count,
            totalPixels: depthData.count,
            averageConfidence: totalConfidence / Float(depthData.count) / 2.0, // Normalize to 0-1
            minDepth: minDepth,
            maxDepth: maxDepth
        )
    }

    /// Filter depth data by confidence threshold
    func filterByConfidence(
        _ depthData: [DepthData],
        minConfidence: ARConfidenceLevel
    ) -> [DepthData] {
        depthData.filter { $0.confidence.rawValue >= minConfidence.rawValue }
    }

    /// Remove outliers using MAD-based statistical filtering (robust to outliers)
    func removeOutliers(_ depthData: [DepthData]) -> [DepthData] {
        guard depthData.count > 10 else { return depthData }

        let depths = depthData.map { $0.depth }
        var sortedDepths = depths.sorted()
        let medianDepth = sortedDepths[sortedDepths.count / 2]

        // MAD (Median Absolute Deviation) — robust estimator
        // Reuse sortedDepths array for absolute deviations to avoid extra allocation
        for i in 0..<sortedDepths.count {
            sortedDepths[i] = abs(depths[i] - medianDepth)
        }
        sortedDepths.sort()
        let mad = sortedDepths[sortedDepths.count / 2]

        // 1.4826 scales MAD to be consistent with stdDev for normal distributions
        let threshold = 3.0 * 1.4826 * mad
        let minDepth = medianDepth - threshold
        let maxDepth = medianDepth + threshold

        return depthData.filter { $0.depth >= minDepth && $0.depth <= maxDepth }
    }

    /// Downsample depth data using grid-based sampling
    func downsample(
        _ depthData: [DepthData],
        gridSize: Int = 4
    ) -> [DepthData] {
        guard !depthData.isEmpty else { return [] }

        // Find bounds in single pass
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for data in depthData {
            minX = min(minX, data.pixelX); maxX = max(maxX, data.pixelX)
            minY = min(minY, data.pixelY); maxY = max(maxY, data.pixelY)
        }

        // Create grid cells
        struct GridKey2D: Hashable {
            let x, y: Int
        }

        var grid: [GridKey2D: [DepthData]] = [:]

        for data in depthData {
            let key = GridKey2D(x: (data.pixelX - minX) / gridSize,
                                y: (data.pixelY - minY) / gridSize)
            grid[key, default: []].append(data)
        }

        // Take the highest confidence point from each cell
        return grid.values.compactMap { cellData in
            cellData.max { $0.confidence.rawValue < $1.confidence.rawValue }
        }
    }
}
