//
//  MeasurementQuality.swift
//  SnapMeasure
//

import Foundation
import ARKit

/// Quality level for measurements
enum QualityLevel: String, Codable {
    case high
    case medium
    case low

    var color: String {
        switch self {
        case .high: return "green"
        case .medium: return "yellow"
        case .low: return "red"
        }
    }

    var description: String {
        switch self {
        case .high: return String(localized: "High confidence measurement")
        case .medium: return String(localized: "Medium confidence - consider remeasuring")
        case .low: return String(localized: "Low confidence - remeasure recommended")
        }
    }
}

/// Quality metrics for a measurement
struct MeasurementQuality: Codable {
    /// Percentage of the mask area with valid depth data (0-1)
    let depthCoverage: Float

    /// Average depth confidence in the mask area (0-1)
    let depthConfidence: Float

    /// Number of points in the point cloud
    let pointCount: Int

    /// Tracking state description
    let trackingStateDescription: String

    /// Whether tracking was in normal state
    let trackingNormal: Bool

    /// Overall quality assessment
    var overallQuality: QualityLevel {
        if trackingNormal &&
           depthCoverage > AppConstants.highDepthCoverage &&
           depthConfidence > AppConstants.highDepthConfidence {
            return .high
        } else if depthCoverage > AppConstants.minDepthCoverage &&
                  depthConfidence > AppConstants.minDepthConfidence {
            return .medium
        } else {
            return .low
        }
    }

    init(
        depthCoverage: Float,
        depthConfidence: Float,
        pointCount: Int,
        trackingState: ARCamera.TrackingState
    ) {
        self.depthCoverage = depthCoverage
        self.depthConfidence = depthConfidence
        self.pointCount = pointCount

        switch trackingState {
        case .normal:
            self.trackingStateDescription = "Normal"
            self.trackingNormal = true
        case .limited(let reason):
            self.trackingNormal = false
            switch reason {
            case .initializing:
                self.trackingStateDescription = "Initializing"
            case .excessiveMotion:
                self.trackingStateDescription = "Excessive Motion"
            case .insufficientFeatures:
                self.trackingStateDescription = "Insufficient Features"
            case .relocalizing:
                self.trackingStateDescription = "Relocalizing"
            @unknown default:
                self.trackingStateDescription = "Limited"
            }
        case .notAvailable:
            self.trackingStateDescription = "Not Available"
            self.trackingNormal = false
        }
    }

    /// Merge multiple quality metrics into one
    static func merged(_ qualities: [MeasurementQuality]) -> MeasurementQuality {
        guard !qualities.isEmpty else {
            return MeasurementQuality(
                depthCoverage: 0, depthConfidence: 0, pointCount: 0,
                trackingStateDescription: "Unknown", trackingNormal: false
            )
        }
        let maxCoverage = qualities.map(\.depthCoverage).max() ?? 0
        let totalPoints = qualities.map(\.pointCount).reduce(0, +)
        let weightedConfidence: Float = {
            guard totalPoints > 0 else { return 0 }
            let sum = qualities.reduce(Float(0)) { $0 + $1.depthConfidence * Float($1.pointCount) }
            return sum / Float(totalPoints)
        }()
        let allNormal = qualities.allSatisfy(\.trackingNormal)
        return MeasurementQuality(
            depthCoverage: maxCoverage,
            depthConfidence: weightedConfidence,
            pointCount: totalPoints,
            trackingStateDescription: allNormal ? "Normal" : "Mixed",
            trackingNormal: allNormal
        )
    }

    /// Create from stored data (for SwiftData)
    init(
        depthCoverage: Float,
        depthConfidence: Float,
        pointCount: Int,
        trackingStateDescription: String,
        trackingNormal: Bool
    ) {
        self.depthCoverage = depthCoverage
        self.depthConfidence = depthConfidence
        self.pointCount = pointCount
        self.trackingStateDescription = trackingStateDescription
        self.trackingNormal = trackingNormal
    }
}
