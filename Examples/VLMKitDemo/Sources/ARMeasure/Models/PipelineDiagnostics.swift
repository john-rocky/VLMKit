//
//  PipelineDiagnostics.swift
//  SnapMeasure
//

#if DEBUG
import Foundation

/// Structured diagnostic data captured during a measurement pipeline run.
/// Each stage is optional — populated as the pipeline progresses.
final class PipelineDiagnostics {

    // MARK: - Stage Status

    enum StageStatus: String {
        case success  = "●"
        case warning  = "▲"
        case failed   = "✕"
        case skipped  = "○"

        var emoji: String { rawValue }
    }

    // MARK: - Stage Structs

    struct InputStage {
        var tapPoint: CGPoint?
        var normalizedTap: CGPoint?
        var roi: CGRect?
        var viewSize: CGSize
        var imageSize: CGSize
        var trackingState: String
        var mode: String
        var selectionMode: String  // "tap" or "box"
    }

    struct SegmentationStage {
        var instanceCount: Int
        var selectedInstance: String  // e.g. "#2 (depth-penalized)" or "ALL"
        var maskPixelCount: Int
        var maskSize: CGSize
        var durationMs: Double
        var status: StageStatus
    }

    struct ConnectedComponentStage {
        var enabled: Bool
        var pixelsBefore: Int
        var pixelsAfter: Int
        var retentionPercent: Double
        var status: StageStatus
    }

    struct DepthConnectivityStage {
        var enabled: Bool
        var pixelsBefore: Int
        var pixelsAfter: Int
        var retentionPercent: Double
        var status: StageStatus
    }

    struct DepthFilterStage {
        var tapDepth: Float
        var tolerance: Float
        var tolerancePercent: Float
        var pixelsBefore: Int
        var pixelsAfter: Int
        var retentionPercent: Double
        var status: StageStatus
    }

    struct PointCloudStage {
        var inputPixels: Int
        var extracted: Int
        var afterOutlierRemoval: Int
        var afterDownsample: Int
        var afterUnproject: Int
        var after3DFilter: Int
        var finalCount: Int
        var depthCoverage: Float
        var depthConfidence: Float
        var status: StageStatus
    }

    struct ClusteringStage {
        var nearestDistToHit: Float
        var proximityRadius: Float
        var pointsAfterProximity: Int
        var pointsAfterClustering: Int
        var method: String  // "clustering", "proximity-only", "skipped"
        var status: StageStatus
    }

    struct BBoxEstimationStage {
        var hullPointCount: Int
        var coarseAngleDeg: Float
        var fineAngleDeg: Float
        var angleDelta: Float
        var refinementIterations: Int
        var method: String  // "MABR", "PCA", "3D-PCA"
        var status: StageStatus
    }

    struct PlaneSnapStage {
        var snapped: Bool
        var planeCount: Int
        var closestDistance: Float?
        var preSnapAngleDeg: Float
        var postSnapAngleDeg: Float
        var snapDelta: Float
        var score: Float
        var method: String  // "weighted", "area-only"
        var status: StageStatus
    }

    struct AxisMappingStage {
        var heightAxisIndex: Int
        var lengthAxisIndex: Int
        var widthAxisIndex: Int
        var heightCm: Float
        var lengthCm: Float
        var widthCm: Float
    }

    struct FloorStage {
        var detected: Bool
        var floorY: Float?
        var boxBottomY: Float?
        var extensionAmount: Float?
        var method: String  // "ARPlane", "raycast", "none"
    }

    // MARK: - Stage Properties

    var input: InputStage?
    var segmentation: SegmentationStage?
    var connectedComponent: ConnectedComponentStage?
    var depthConnectivity: DepthConnectivityStage?
    var depthFilter: DepthFilterStage?
    var pointCloud: PointCloudStage?
    var clustering: ClusteringStage?
    var bboxEstimation: BBoxEstimationStage?
    var planeSnap: PlaneSnapStage?
    var axisMapping: AxisMappingStage?
    var floor: FloorStage?

    // MARK: - Overall

    var pipelineVersion: String = ""
    var overallDurationMs: Double = 0
    var failedAtStage: String?
    var failureReason: String?

    /// Ordered list of stages for display
    var stages: [(name: String, status: StageStatus, summary: String)] {
        var result: [(String, StageStatus, String)] = []

        if let s = input {
            let point = s.tapPoint.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "ROI"
            result.append(("INPUT", .success, "\(s.selectionMode) \(point), \(Int(s.imageSize.width))×\(Int(s.imageSize.height))"))
        }

        if let s = segmentation {
            result.append(("SEGMENTATION", s.status,
                "\(s.instanceCount) inst, \(formatCount(s.maskPixelCount)) px, \(String(format: "%.0f", s.durationMs))ms"))
        }

        if let s = connectedComponent, s.enabled {
            result.append(("CONNECTED COMP", s.status,
                "\(formatCount(s.pixelsBefore))→\(formatCount(s.pixelsAfter)) px (\(String(format: "%.0f", s.retentionPercent))%)"))
        }

        if let s = depthConnectivity, s.enabled {
            result.append(("DEPTH CONNECT", s.status,
                "\(formatCount(s.pixelsBefore))→\(formatCount(s.pixelsAfter)) px (\(String(format: "%.0f", s.retentionPercent))%)"))
        }

        if let s = depthFilter {
            result.append(("DEPTH FILTER", s.status,
                "\(String(format: "%.2f", s.tapDepth))m ±\(String(format: "%.2f", s.tolerance))m, \(formatCount(s.pixelsBefore))→\(formatCount(s.pixelsAfter)) px (\(String(format: "%.0f", s.retentionPercent))%)"))
        }

        if let s = pointCloud {
            result.append(("POINT CLOUD", s.status,
                "\(formatCount(s.finalCount)) pts, cov \(String(format: "%.0f", s.depthCoverage * 100))%"))
        }

        if let s = clustering {
            result.append(("CLUSTERING", s.status,
                "hit \(String(format: "%.3f", s.nearestDistToHit))m, r=\(String(format: "%.2f", s.proximityRadius))m, \(formatCount(s.pointsAfterClustering)) pts"))
        }

        if let s = bboxEstimation {
            result.append(("BBOX ESTIMATION", s.status,
                "\(s.method), hull \(s.hullPointCount)pts, \(String(format: "%.1f", s.fineAngleDeg))°"))
        }

        if let s = planeSnap {
            let snapStr = s.snapped ? "→\(String(format: "%.1f", s.postSnapAngleDeg))° (Δ\(String(format: "%.1f", s.snapDelta))°)" : "no snap"
            result.append(("PLANE SNAP", s.status, snapStr))
        }

        if let s = axisMapping {
            result.append(("AXIS MAPPING", .success,
                "H=\(String(format: "%.1f", s.heightCm))cm L=\(String(format: "%.1f", s.lengthCm))cm W=\(String(format: "%.1f", s.widthCm))cm"))
        }

        if let s = floor {
            let detail = s.detected ? "Y=\(String(format: "%.3f", s.floorY ?? 0)), ext \(String(format: "%.1f", (s.extensionAmount ?? 0) * 100))cm" : "not detected"
            result.append(("FLOOR", s.detected ? .success : .skipped, detail))
        }

        return result
    }

    var succeeded: Bool { failedAtStage == nil }

    private func formatCount(_ n: Int) -> String {
        if n >= 10_000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}
#endif
