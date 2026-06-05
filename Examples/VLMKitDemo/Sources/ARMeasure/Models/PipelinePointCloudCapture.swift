//
//  PipelinePointCloudCapture.swift
//  SnapMeasure
//

#if DEBUG
import simd

/// Captures intermediate 3D point arrays at each pipeline stage for visual debugging.
/// Allows comparing kept vs removed points between stages.
class PipelinePointCloudCapture {
    // MARK: - Stage Definition

    enum Stage: Int, CaseIterable {
        case afterUnproject = 0
        case after3DOutlierRemoval = 1
        case after3DDownsample = 2
        case afterProximityFilter = 3
        case afterClustering = 4

        var displayName: String {
            switch self {
            case .afterUnproject:         return "Unproject"
            case .after3DOutlierRemoval:  return "3D Outlier"
            case .after3DDownsample:      return "3D Downsample"
            case .afterProximityFilter:   return "Proximity"
            case .afterClustering:        return "Clustering"
            }
        }

        /// Previous stage in the pipeline (nil for the first stage)
        var previous: Stage? {
            Stage(rawValue: rawValue - 1)
        }
    }

    // MARK: - Storage

    var pointsByStage: [Stage: [SIMD3<Float>]] = [:]

    // MARK: - Capture

    func capture(points: [SIMD3<Float>], at stage: Stage) {
        pointsByStage[stage] = points
    }

    // MARK: - Query

    /// Points kept at a given stage
    func keptPoints(at stage: Stage) -> [SIMD3<Float>] {
        pointsByStage[stage] ?? []
    }

    /// Points removed at a given stage (present in previous stage but not in this one)
    func removedPoints(at stage: Stage) -> [SIMD3<Float>] {
        guard let previous = stage.previous,
              let prevPoints = pointsByStage[previous],
              let currentPoints = pointsByStage[stage] else {
            return []
        }

        // Build set of current points for O(1) lookup
        // Use quantized keys since floating point equality is unreliable
        struct PointKey: Hashable {
            let x, y, z: Int32
            init(_ p: SIMD3<Float>) {
                // Quantize to 0.1mm resolution
                x = Int32(p.x * 10000)
                y = Int32(p.y * 10000)
                z = Int32(p.z * 10000)
            }
        }
        let currentSet = Set(currentPoints.map { PointKey($0) })
        return prevPoints.filter { !currentSet.contains(PointKey($0)) }
    }

    /// Count of kept points at stage
    func keptCount(at stage: Stage) -> Int {
        pointsByStage[stage]?.count ?? 0
    }

    /// Count of removed points at stage
    func removedCount(at stage: Stage) -> Int {
        removedPoints(at: stage).count
    }
}
#endif
