//
//  DepthSource.swift
//  ProductMeasure
//

import ARKit

/// Abstraction over depth data source (LiDAR vs ML model)
protocol DepthSource {
    /// Whether this source provides metric (absolute) depth
    var isMetric: Bool { get }

    /// Whether a real confidence map is available
    var hasConfidenceMap: Bool { get }

    /// Extract depth map for the given frame
    func depthMap(for frame: ARFrame) -> CVPixelBuffer?

    /// Extract confidence map for the given frame (nil if not available)
    func confidenceMap(for frame: ARFrame) -> CVPixelBuffer?
}

/// LiDAR-based depth source — wraps ARFrame.sceneDepth
struct LiDARDepthSource: DepthSource {
    let isMetric = true
    let hasConfidenceMap = true

    func depthMap(for frame: ARFrame) -> CVPixelBuffer? {
        frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
    }

    func confidenceMap(for frame: ARFrame) -> CVPixelBuffer? {
        frame.smoothedSceneDepth?.confidenceMap ?? frame.sceneDepth?.confidenceMap
    }
}
