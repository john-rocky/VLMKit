//
//  LiDARChecker.swift
//  SnapMeasure
//

import ARKit

enum DepthMode {
    case lidar          // LiDAR hardware depth
    case mlFallback     // ML model depth estimation
    case none           // No depth available (ARKit not supported)
}

enum LiDARChecker {
    /// Check if the device supports LiDAR depth sensing
    static var isLiDARAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Check if the device supports smoothed scene depth
    static var isSmoothedDepthAvailable: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
    }

    /// Check if ARKit is supported on this device
    static var isARKitSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// Determine the best available depth mode
    static var depthMode: DepthMode {
        if isLiDARAvailable { return .lidar }
        if isARKitSupported { return .mlFallback }
        return .none
    }

    /// Create the appropriate depth source for this device
    static func createDepthSource() -> DepthSource? {
        switch depthMode {
        case .lidar: return LiDARDepthSource()
        case .mlFallback: return MLDepthEstimator()
        case .none: return nil
        }
    }

    /// Get a user-friendly message about device capabilities
    static var capabilityMessage: String? {
        if !isARKitSupported {
            return "This device does not support ARKit."
        }
        return nil
    }
}
