//
//  BoundingBoxEstimator.swift
//  SnapMeasure
//

import simd
import Foundation
import ARKit

/// Estimates oriented bounding boxes from point clouds using MABR (Minimum Area Bounding Rectangle)
class BoundingBoxEstimator {

    // MARK: - Diagnostics

    #if DEBUG
    struct EstimationDetails {
        var hullPointCount: Int = 0
        var coarseAngleDeg: Float = 0
        var fineAngleDeg: Float = 0
        var snapped: Bool = false
        var preSnapAngleDeg: Float = 0
        var postSnapAngleDeg: Float = 0
        var snapScore: Float = 0
        var planeCount: Int = 0
        var closestPlaneDistance: Float?
        var refinementIterations: Int = 0
        var method: String = "MABR"
    }

    private(set) var lastEstimationDetails: EstimationDetails?
    #endif

    // MARK: - Public Methods

    /// Estimate an oriented bounding box for a point cloud
    /// - Parameters:
    ///   - points: 3D points in world coordinates
    ///   - mode: Measurement mode (box priority or free object)
    ///   - verticalPlaneAnchors: Optional vertical plane anchors for orientation snapping
    /// - Returns: Oriented bounding box
    func estimateBoundingBox(
        points: [SIMD3<Float>],
        mode: MeasurementMode,
        verticalPlaneAnchors: [ARPlaneAnchor] = []
    ) -> BoundingBox3D? {
        guard points.count >= 4 else { return nil }

        switch mode {
        case .boxPriority:
            return estimateBoxPriorityOBB(points: points, verticalPlaneAnchors: verticalPlaneAnchors)
        case .freeObject:
            return estimateFreeObjectOBB(points: points)
        }
    }

    // MARK: - Box Priority Mode

    /// Estimate OBB with vertical axis locked to world Y-axis
    /// Uses MABR (Minimum Area Bounding Rectangle) for horizontal orientation
    private func estimateBoxPriorityOBB(
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> BoundingBox3D? {
        #if DEBUG
        var details = EstimationDetails()
        details.planeCount = verticalPlaneAnchors.count
        #endif

        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Project points onto horizontal plane (XZ)
        let horizontalPoints = points.map { SIMD2<Float>($0.x, $0.z) }

        // Use MABR for orientation (fall back to PCA if too few points for convex hull)
        let xAxis: SIMD3<Float>
        let zAxis: SIMD3<Float>

        let pipeline = AppConstants.currentPipelineVersion

        if horizontalPoints.count >= 20 {
            let hull = convexHull2D(horizontalPoints)
            if hull.count >= 3 {
                #if DEBUG
                details.hullPointCount = hull.count
                #endif

                var mabrAngle = minimumAreaBoundingRect(hull: hull)
                #if DEBUG
                details.coarseAngleDeg = mabrAngle * 180 / .pi
                #endif

                if pipeline.useFineAngleSearch {
                    mabrAngle = fineAngleSearch(baseAngle: mabrAngle, hull: hull)
                }
                #if DEBUG
                details.fineAngleDeg = mabrAngle * 180 / .pi
                details.preSnapAngleDeg = mabrAngle * 180 / .pi
                #endif

                // Snap to vertical plane if one is nearby and aligned
                mabrAngle = snapToVerticalPlane(
                    angle: mabrAngle,
                    boxCenter: centroid,
                    verticalPlaneAnchors: verticalPlaneAnchors,
                    useWeightedScoring: pipeline.useWeightedPlaneSnap
                )
                #if DEBUG
                details.postSnapAngleDeg = mabrAngle * 180 / .pi
                details.snapped = abs(details.preSnapAngleDeg - details.postSnapAngleDeg) > 0.01
                #endif

                let cosA = cos(mabrAngle)
                let sinA = sin(mabrAngle)
                xAxis = SIMD3<Float>(cosA, 0, sinA).normalized
                zAxis = SIMD3<Float>(-sinA, 0, cosA).normalized
            } else {
                // Degenerate hull, fall back to PCA
                let (ax, az) = pcaHorizontalAxes(horizontalPoints)
                xAxis = ax
                zAxis = az
                #if DEBUG
                details.method = "PCA"
                #endif
            }
        } else {
            // Too few points for reliable hull, fall back to PCA
            let (ax, az) = pcaHorizontalAxes(horizontalPoints)
            xAxis = ax
            zAxis = az
            #if DEBUG
            details.method = "PCA"
            #endif
        }

        let yAxis = SIMD3<Float>(0, 1, 0)

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Compute extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        let initialBox = BoundingBox3D(center: center, extents: extents, rotation: rotation)

        // Iterative refinement
        let result = refineBoxIteratively(initialBox: initialBox, points: points, verticalPlaneAnchors: verticalPlaneAnchors)

        #if DEBUG
        details.refinementIterations = pipeline.boxRefinementIterations
        lastEstimationDetails = details
        #endif

        return result
    }

    // MARK: - Free Object Mode

    /// Estimate OBB using full 3D PCA
    /// Works for irregularly shaped or tilted objects
    private func estimateFreeObjectOBB(points: [SIMD3<Float>]) -> BoundingBox3D? {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Compute 3D covariance matrix
        let covariance = computeCovariance3D(points, centroid: centroid)

        // 3D PCA
        let (_, eigenvectors) = eigenDecomposition(covariance)

        // Ensure right-handed coordinate system
        var xAxis = SIMD3<Float>(eigenvectors.columns.0.x, eigenvectors.columns.0.y, eigenvectors.columns.0.z)
        var yAxis = SIMD3<Float>(eigenvectors.columns.1.x, eigenvectors.columns.1.y, eigenvectors.columns.1.z)
        var zAxis = xAxis.cross(yAxis)

        // Re-orthogonalize
        yAxis = zAxis.cross(xAxis).normalized
        xAxis = xAxis.normalized
        zAxis = zAxis.normalized

        let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
        let rotation = simd_quatf(rotationMatrix: rotationMatrix)

        // Compute extents
        let (center, extents) = computeExtents(points: points, centroid: centroid, rotation: rotation)

        return BoundingBox3D(center: center, extents: extents, rotation: rotation)
    }

    // MARK: - Convex Hull (Andrew's Monotone Chain)

    /// Compute the 2D convex hull of XZ-projected points
    /// Uses Andrew's monotone chain algorithm, O(n log n)
    private func convexHull2D(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }

        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }

        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2 && cross2D(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross2D(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        // Remove last point of each half because it's repeated
        lower.removeLast()
        upper.removeLast()

        return lower + upper
    }

    /// 2D cross product for convex hull: (b-a) x (c-a)
    private func cross2D(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    // MARK: - Minimum Area Bounding Rectangle (Rotating Calipers)

    /// Find the rotation angle (radians) of the minimum-area bounding rectangle
    /// for a convex hull on the XZ plane
    private func minimumAreaBoundingRect(hull: [SIMD2<Float>]) -> Float {
        guard hull.count >= 3 else { return 0 }

        var bestAngle: Float = 0
        var bestArea: Float = .infinity

        let n = hull.count
        for i in 0..<n {
            let j = (i + 1) % n
            let edge = hull[j] - hull[i]
            let angle = atan2(edge.y, edge.x)

            let cosA = cos(-angle)
            let sinA = sin(-angle)

            var minX: Float = .infinity, maxX: Float = -.infinity
            var minY: Float = .infinity, maxY: Float = -.infinity

            for p in hull {
                let rx = p.x * cosA - p.y * sinA
                let ry = p.x * sinA + p.y * cosA
                minX = min(minX, rx); maxX = max(maxX, rx)
                minY = min(minY, ry); maxY = max(maxY, ry)
            }

            let area = (maxX - minX) * (maxY - minY)
            if area < bestArea {
                bestArea = area
                bestAngle = angle
            }
        }

        return bestAngle
    }

    // MARK: - Fine Angle Search

    /// Fine-grained angle search around the best MABR angle
    /// Searches ±5° in 0.5° steps for a tighter minimum area
    private func fineAngleSearch(baseAngle: Float, hull: [SIMD2<Float>]) -> Float {
        var bestAngle = baseAngle
        var bestArea = computeRotatedArea(hull: hull, angle: baseAngle)

        let range = AppConstants.mabrFineSearchRange
        let step = AppConstants.currentPipelineVersion.mabrStep

        var testAngle = baseAngle - range
        while testAngle <= baseAngle + range {
            let area = computeRotatedArea(hull: hull, angle: testAngle)
            if area < bestArea {
                bestArea = area
                bestAngle = testAngle
            }
            testAngle += step
        }

        return bestAngle
    }

    /// Compute the bounding rectangle area for a hull at a given rotation angle
    private func computeRotatedArea(hull: [SIMD2<Float>], angle: Float) -> Float {
        let cosA = cos(-angle)
        let sinA = sin(-angle)

        var minX: Float = .infinity, maxX: Float = -.infinity
        var minY: Float = .infinity, maxY: Float = -.infinity

        for p in hull {
            let rx = p.x * cosA - p.y * sinA
            let ry = p.x * sinA + p.y * cosA
            minX = min(minX, rx); maxX = max(maxX, rx)
            minY = min(minY, ry); maxY = max(maxY, ry)
        }

        return (maxX - minX) * (maxY - minY)
    }

    // MARK: - Iterative Box Refinement

    /// Multi-pass refinement: filter outlier points to refine angle, but compute
    /// final extents from ALL original points to prevent iterative shrinkage
    private func refineBoxIteratively(
        initialBox: BoundingBox3D,
        points: [SIMD3<Float>],
        verticalPlaneAnchors: [ARPlaneAnchor]
    ) -> BoundingBox3D {
        let margin = AppConstants.boxRefinementMargin
        let minRetainRatio = AppConstants.boxRefinementMinRetainRatio
        let pipeline = AppConstants.currentPipelineVersion
        let iterations = pipeline.boxRefinementIterations

        var currentBox = initialBox

        for iteration in 0..<iterations {
            let inverseRotation = currentBox.rotation.inverse
            // Always filter from ALL original points (not progressively filtered)
            let filteredPoints = points.filter { point in
                let local = inverseRotation.act(point - currentBox.center)
                let ex = currentBox.extents.x + margin
                let ey = currentBox.extents.y + margin
                let ez = currentBox.extents.z + margin
                return abs(local.x) <= ex && abs(local.y) <= ey && abs(local.z) <= ez
            }

            // If too many points pruned, stop refinement
            guard Float(filteredPoints.count) >= Float(points.count) * minRetainRatio,
                  filteredPoints.count >= 20 else {
                break
            }

            let centroid = filteredPoints.reduce(.zero, +) / Float(filteredPoints.count)
            let horizontalPoints = filteredPoints.map { SIMD2<Float>($0.x, $0.z) }

            guard horizontalPoints.count >= 20 else { break }
            let hull = convexHull2D(horizontalPoints)
            guard hull.count >= 3 else { break }

            // Use filtered points for angle refinement only
            var angle = minimumAreaBoundingRect(hull: hull)
            if pipeline.useFineAngleSearch {
                angle = fineAngleSearch(baseAngle: angle, hull: hull)
            }
            angle = snapToVerticalPlane(
                angle: angle,
                boxCenter: centroid,
                verticalPlaneAnchors: verticalPlaneAnchors,
                useWeightedScoring: pipeline.useWeightedPlaneSnap
            )

            let cosA = cos(angle)
            let sinA = sin(angle)
            let xAxis = SIMD3<Float>(cosA, 0, sinA).normalized
            let yAxis = SIMD3<Float>(0, 1, 0)
            let zAxis = SIMD3<Float>(-sinA, 0, cosA).normalized

            let rotationMatrix = simd_float3x3(xAxis, yAxis, zAxis)
            let rotation = simd_quatf(rotationMatrix: rotationMatrix)

            // Compute extents from ALL original points with the refined angle
            let fullCentroid = points.reduce(.zero, +) / Float(points.count)
            let (center, extents) = computeExtents(points: points, centroid: fullCentroid, rotation: rotation)

            currentBox = BoundingBox3D(center: center, extents: extents, rotation: rotation)

#if DEBUG
            print("[BBoxEstimator] Refinement iteration \(iteration + 1): angle=\(angle * 180 / .pi)°")
#endif
        }

        return currentBox
    }

    // MARK: - AR Plane-Assisted Orientation Snap

    /// Snap MABR angle to a nearby vertical plane's orientation if closely aligned
    /// Uses weighted scoring: proximity (50%) + alignment (30%) + area (20%) when useWeightedScoring is true
    /// Falls back to area-only scoring when useWeightedScoring is false (v1 original behavior)
    private func snapToVerticalPlane(
        angle: Float,
        boxCenter: SIMD3<Float>,
        verticalPlaneAnchors: [ARPlaneAnchor],
        useWeightedScoring: Bool = true
    ) -> Float {
        guard !verticalPlaneAnchors.isEmpty else { return angle }

        let maxDistance: Float = 2.0     // Only consider planes within 2m
        let snapThreshold: Float = 10.0 * .pi / 180.0  // 10 degrees

        var bestPlaneAngle: Float?
        var bestScore: Float = 0

        // Find maximum plane area for normalization (used in weighted mode)
        let maxPlaneArea = verticalPlaneAnchors.map { $0.extent.x * $0.extent.z }.max() ?? 1.0

        for anchor in verticalPlaneAnchors {
            // Distance from box center to plane center
            let planePos = SIMD3<Float>(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            let dist = simd_distance(
                SIMD2<Float>(boxCenter.x, boxCenter.z),
                SIMD2<Float>(planePos.x, planePos.z)
            )
            guard dist <= maxDistance else { continue }

            // Project plane normal onto XZ to get its 2D angle
            let normal = SIMD3<Float>(
                anchor.transform.columns.2.x,
                anchor.transform.columns.2.y,
                anchor.transform.columns.2.z
            )
            let planeAngle = atan2(normal.z, normal.x)

            let planeArea = anchor.extent.x * anchor.extent.z

            for offset in [Float(0), .pi / 2, -.pi / 2, .pi] {
                var diff = (angle + offset) - planeAngle
                // Normalize to [-pi, pi]
                while diff > .pi { diff -= 2 * .pi }
                while diff < -.pi { diff += 2 * .pi }

                guard abs(diff) < snapThreshold else { continue }

                let score: Float
                if useWeightedScoring {
                    // Current: weighted scoring (proximity + alignment + area)
                    let proximityScore = 1.0 - (dist / maxDistance)
                    let alignmentScore = 1.0 - abs(diff) / snapThreshold
                    let areaScore = planeArea / maxPlaneArea

                    score = proximityScore * AppConstants.planeSnapProximityWeight +
                            alignmentScore * AppConstants.planeSnapAlignmentWeight +
                            areaScore * AppConstants.planeSnapAreaWeight
                } else {
                    // v1 original: pick by largest plane area only
                    score = planeArea
                }

                if score > bestScore {
                    bestPlaneAngle = planeAngle - offset
                    bestScore = score
                }
            }
        }

        if let snapped = bestPlaneAngle {
#if DEBUG
            print("[BBoxEstimator] Snapped angle to vertical plane: \(angle * 180 / .pi)° -> \(snapped * 180 / .pi)° (score: \(bestScore))")
            lastEstimationDetails?.snapScore = bestScore
#endif
            return snapped
        }

        return angle
    }

    // MARK: - PCA Fallback

    /// PCA-based horizontal axis estimation (fallback for small point counts)
    private func pcaHorizontalAxes(_ horizontalPoints: [SIMD2<Float>]) -> (xAxis: SIMD3<Float>, zAxis: SIMD3<Float>) {
        let covariance2D = computeCovariance2D(horizontalPoints)
        let (_, eigenvectors2D) = eigenDecomposition2D(covariance2D)

        let xAxis = SIMD3<Float>(eigenvectors2D.columns.0.x, 0, eigenvectors2D.columns.0.y).normalized
        let zAxis = xAxis.cross(SIMD3<Float>(0, 1, 0)).normalized

        return (xAxis, zAxis)
    }

    // MARK: - Helper Methods

    private func computeCovariance3D(_ points: [SIMD3<Float>], centroid: SIMD3<Float>) -> simd_float3x3 {
        var cov = simd_float3x3(0)

        for point in points {
            let d = point - centroid
            cov.columns.0 += SIMD3<Float>(d.x * d.x, d.x * d.y, d.x * d.z)
            cov.columns.1 += SIMD3<Float>(d.y * d.x, d.y * d.y, d.y * d.z)
            cov.columns.2 += SIMD3<Float>(d.z * d.x, d.z * d.y, d.z * d.z)
        }

        let n = Float(points.count)
        cov.columns.0 /= n
        cov.columns.1 /= n
        cov.columns.2 /= n

        return cov
    }

    private func computeCovariance2D(_ points: [SIMD2<Float>]) -> simd_float2x2 {
        let centroid = points.reduce(.zero, +) / Float(points.count)

        var cov = simd_float2x2(0)

        for point in points {
            let d = point - centroid
            cov.columns.0 += SIMD2<Float>(d.x * d.x, d.x * d.y)
            cov.columns.1 += SIMD2<Float>(d.y * d.x, d.y * d.y)
        }

        let n = Float(points.count)
        cov.columns.0 /= n
        cov.columns.1 /= n

        return cov
    }

    /// 2D eigenvalue decomposition for symmetric matrix
    private func eigenDecomposition2D(_ matrix: simd_float2x2) -> (eigenvalues: SIMD2<Float>, eigenvectors: simd_float2x2) {
        let a = matrix.columns.0.x
        let b = matrix.columns.1.x
        let c = matrix.columns.0.y
        let d = matrix.columns.1.y

        let trace = a + d
        let det = a * d - b * c

        let discriminant = sqrt(max(0, trace * trace / 4 - det))
        let lambda1 = trace / 2 + discriminant
        let lambda2 = trace / 2 - discriminant

        var v1: SIMD2<Float>
        var v2: SIMD2<Float>

        if abs(b) > 1e-10 {
            v1 = SIMD2<Float>(lambda1 - d, b).normalized
            v2 = SIMD2<Float>(lambda2 - d, b).normalized
        } else if abs(c) > 1e-10 {
            v1 = SIMD2<Float>(c, lambda1 - a).normalized
            v2 = SIMD2<Float>(c, lambda2 - a).normalized
        } else {
            v1 = SIMD2<Float>(1, 0)
            v2 = SIMD2<Float>(0, 1)
        }

        return (SIMD2<Float>(lambda1, lambda2), simd_float2x2(v1, v2))
    }

    private func computeExtents(
        points: [SIMD3<Float>],
        centroid: SIMD3<Float>,
        rotation: simd_quatf
    ) -> (center: SIMD3<Float>, extents: SIMD3<Float>) {
        let inverseRotation = rotation.inverse
        let n = points.count

        // Single pass: transform to local space and distribute into 3 pre-allocated arrays
        var xVals = [Float]()
        var yVals = [Float]()
        var zVals = [Float]()
        xVals.reserveCapacity(n)
        yVals.reserveCapacity(n)
        zVals.reserveCapacity(n)

        for point in points {
            let local = inverseRotation.act(point - centroid)
            xVals.append(local.x)
            yVals.append(local.y)
            zVals.append(local.z)
        }

        // Use percentile-based extents to trim extreme noise
        // Trim 2% from each side per axis for tighter fit
        let trimCount = max(1, Int(Float(n) * AppConstants.extentsTrimPercent))

        xVals.sort()
        yVals.sort()
        zVals.sort()

        let lo = max(0, trimCount)
        let hi = max(lo + 1, n - 1 - trimCount)

        let minLocal = SIMD3<Float>(xVals[lo], yVals[lo], zVals[lo])
        let maxLocal = SIMD3<Float>(xVals[hi], yVals[hi], zVals[hi])

        // Compute the true box center (not the centroid)
        let localCenter = (minLocal + maxLocal) / 2
        let adjustedCenter = centroid + rotation.act(localCenter)

        // Extents are half-sizes
        let extents = (maxLocal - minLocal) / 2

        return (center: adjustedCenter, extents: extents)
    }
}

// MARK: - SIMD2 Extensions

extension SIMD2 where Scalar == Float {
    var normalized: SIMD2<Float> {
        let len = simd_length(self)
        return len > 0 ? self / len : self
    }
}
