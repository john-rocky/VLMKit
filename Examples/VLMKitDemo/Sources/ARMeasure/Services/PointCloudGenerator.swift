//
//  PointCloudGenerator.swift
//  SnapMeasure
//

import ARKit
import simd

/// Generates 3D point clouds from depth data
class PointCloudGenerator {
    // MARK: - Types

    struct PointCloud {
        /// 3D points in world coordinates
        let points: [SIMD3<Float>]

        /// Quality metrics
        let quality: MeasurementQuality

        var centroid: SIMD3<Float> {
            guard !points.isEmpty else { return .zero }
            return points.reduce(.zero, +) / Float(points.count)
        }

        var isEmpty: Bool { points.isEmpty }
    }

    // MARK: - Diagnostics

    #if DEBUG
    struct GenerationDetails {
        var inputPixels: Int = 0
        var extracted: Int = 0
        var afterOutlierRemoval: Int = 0
        var afterDownsample: Int = 0
        var afterUnproject: Int = 0
        var after3DFilter: Int = 0
        var finalCount: Int = 0
    }

    private(set) var lastGenerationDetails: GenerationDetails?
    private(set) var lastPointCloudCapture: PipelinePointCloudCapture?
    #endif

    // MARK: - Properties

    private let depthProcessor = DepthProcessor()

    // MARK: - Public Methods

    /// Generate a point cloud from segmented object
    /// - Parameters:
    ///   - frame: ARFrame with depth data
    ///   - mask: Segmentation mask
    ///   - imageSize: Camera image size
    ///   - depthSource: Depth source (LiDAR or ML fallback)
    /// - Returns: PointCloud with 3D world coordinates
    func generatePointCloud(
        frame: ARFrame,
        maskedPixels: [(x: Int, y: Int)],
        imageSize: CGSize,
        depthSource: DepthSource? = nil
    ) -> PointCloud {
        #if DEBUG
        print("[PointCloud] Starting with \(maskedPixels.count) masked pixels")
        var genDetails = GenerationDetails()
        genDetails.inputPixels = maskedPixels.count
        let pcCapture = PipelinePointCloudCapture()
        #endif

        // Extract depth data for masked pixels
        var depthData = depthProcessor.extractDepthForMask(
            frame: frame,
            maskedPixels: maskedPixels,
            imageSize: imageSize,
            depthSource: depthSource
        )

        let totalMaskedPixels = maskedPixels.count
        #if DEBUG
        print("[PointCloud] Extracted \(depthData.count) depth points")
        genDetails.extracted = depthData.count
        #endif

        guard !depthData.isEmpty else {
            return PointCloud(
                points: [],
                quality: MeasurementQuality(
                    depthCoverage: 0,
                    depthConfidence: 0,
                    pointCount: 0,
                    trackingState: frame.camera.trackingState
                )
            )
        }

        // Remove outliers
        depthData = depthProcessor.removeOutliers(depthData)
        #if DEBUG
        print("[PointCloud] After outlier removal: \(depthData.count) points")
        genDetails.afterOutlierRemoval = depthData.count
        #endif

        // Downsample if too many points
        if depthData.count > AppConstants.maxPointCloudSize {
            depthData = depthProcessor.downsample(depthData, gridSize: 4)
            #if DEBUG
            print("[PointCloud] After downsampling: \(depthData.count) points")
            #endif
        }
        #if DEBUG
        genDetails.afterDownsample = depthData.count
        #endif

        // Get depth stats
        let stats = depthProcessor.getDepthStats(depthData: depthData)
        #if DEBUG
        print("[PointCloud] Depth range: \(stats.minDepth)m - \(stats.maxDepth)m")
        #endif

        // Get depth map size
        let depthMapForSize = depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        guard let depthMap = depthMapForSize else {
            return PointCloud(
                points: [],
                quality: MeasurementQuality(
                    depthCoverage: 0,
                    depthConfidence: 0,
                    pointCount: 0,
                    trackingState: frame.camera.trackingState
                )
            )
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        #if DEBUG
        print("[PointCloud] Depth map size: \(depthWidth)x\(depthHeight)")
        #endif

        // Unproject to 3D world coordinates
        let points = unprojectToWorld(
            depthData: depthData,
            frame: frame,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
        #if DEBUG
        print("[PointCloud] Unprojected \(points.count) points")
        genDetails.afterUnproject = points.count
        pcCapture.capture(points: points, at: .afterUnproject)
        #endif

        // Filter outliers in 3D space
        let filteredPoints = filter3DOutliers(points)
        #if DEBUG
        print("[PointCloud] After 3D outlier filter: \(filteredPoints.count) points")
        genDetails.after3DFilter = filteredPoints.count
        pcCapture.capture(points: filteredPoints, at: .after3DOutlierRemoval)
        #endif

        // Grid-based downsampling in 3D
        let downsampledPoints = downsample3D(filteredPoints, gridSize: AppConstants.pointCloudGridSize)
        #if DEBUG
        print("[PointCloud] Final point count: \(downsampledPoints.count)")
        genDetails.finalCount = downsampledPoints.count
        pcCapture.capture(points: downsampledPoints, at: .after3DDownsample)
        #endif

        #if DEBUG
        if let first = downsampledPoints.first {
            print("[PointCloud] Sample point: \(first)")
        }
        #endif

        let quality = MeasurementQuality(
            depthCoverage: Float(depthData.count) / Float(max(totalMaskedPixels, 1)),
            depthConfidence: stats.averageConfidence,
            pointCount: downsampledPoints.count,
            trackingState: frame.camera.trackingState
        )

        #if DEBUG
        lastGenerationDetails = genDetails
        lastPointCloudCapture = pcCapture
        print("[PointCloud] Capture saved: unproject=\(pcCapture.keptCount(at: .afterUnproject)), outlier=\(pcCapture.keptCount(at: .after3DOutlierRemoval)), downsample=\(pcCapture.keptCount(at: .after3DDownsample))")
        #endif

        return PointCloud(points: downsampledPoints, quality: quality)
    }

    // MARK: - Private Methods

    private func unprojectToWorld(
        depthData: [DepthProcessor.DepthData],
        frame: ARFrame,
        depthWidth: Int,
        depthHeight: Int
    ) -> [SIMD3<Float>] {
        let camera = frame.camera

        // Get the camera's transform (position and orientation in world space)
        let cameraTransform = camera.transform

        // Get intrinsics for the camera image
        let intrinsics = camera.intrinsics

        // Image dimensions from capturedImage
        let imageWidth = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageHeight = Float(CVPixelBufferGetHeight(frame.capturedImage))

        // Also check camera.imageResolution to ensure they match
        let cameraImageWidth = Float(camera.imageResolution.width)
        let cameraImageHeight = Float(camera.imageResolution.height)

        // Scale factors from depth map to camera image
        let scaleX = imageWidth / Float(depthWidth)
        let scaleY = imageHeight / Float(depthHeight)

        // Intrinsic parameters from camera (calibrated for camera.imageResolution)
        // If capturedImage has different resolution, we need to scale the intrinsics
        var fx = intrinsics[0][0]
        var fy = intrinsics[1][1]
        var cx = intrinsics[2][0]
        var cy = intrinsics[2][1]

        // Scale intrinsics if image resolution differs from camera.imageResolution
        if abs(imageWidth - cameraImageWidth) > 1 || abs(imageHeight - cameraImageHeight) > 1 {
            let scaleIntrinsicsX = imageWidth / cameraImageWidth
            let scaleIntrinsicsY = imageHeight / cameraImageHeight
            fx *= scaleIntrinsicsX
            fy *= scaleIntrinsicsY
            cx *= scaleIntrinsicsX
            cy *= scaleIntrinsicsY
            #if DEBUG
            print("[Unproject] WARNING: Scaling intrinsics by \(scaleIntrinsicsX), \(scaleIntrinsicsY)")
            #endif
        }

        // Debug: Print camera info once
        if depthData.count > 0 {
            #if DEBUG
            print("[Unproject] Image size: \(imageWidth)x\(imageHeight)")
            print("[Unproject] Camera image resolution: \(cameraImageWidth)x\(cameraImageHeight)")
            print("[Unproject] Depth map size: \(depthWidth)x\(depthHeight)")
            print("[Unproject] Scale factors (depth to image): \(scaleX), \(scaleY)")
            print("[Unproject] Intrinsics: fx=\(fx), fy=\(fy), cx=\(cx), cy=\(cy)")
            print("[Unproject] Camera position: \(cameraTransform.columns.3)")
            #endif
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(depthData.count)
        var debugCount = 0

        for data in depthData {
            let depth = data.depth

            // Convert depth pixel coordinates to camera image coordinates
            let imageX = Float(data.pixelX) * scaleX
            let imageY = Float(data.pixelY) * scaleY

            // Unproject to camera-local 3D coordinates
            // Standard pinhole camera model: X = (u - cx) * Z / fx
            let localX = (imageX - cx) * depth / fx
            let localY = (imageY - cy) * depth / fy

            // In ARKit camera local space:
            // +X is right, +Y is up, +Z is towards the user (behind the camera)
            // So a point at positive depth (in front) is at negative Z
            let cameraSpacePoint = SIMD4<Float>(localX, -localY, -depth, 1.0)

            // Transform to world space
            let worldPoint = cameraTransform * cameraSpacePoint

            // Debug first few points
            if debugCount < 3 {
                #if DEBUG
                print("[Unproject] Point \(debugCount): depth=\(depth)m, depthPx=(\(data.pixelX),\(data.pixelY)), imagePx=(\(imageX),\(imageY))")
                print("[Unproject]   -> camera local: (\(localX), \(-localY), \(-depth))")
                print("[Unproject]   -> world: (\(worldPoint.x), \(worldPoint.y), \(worldPoint.z))")
                #endif
                debugCount += 1
            }

            points.append(SIMD3(worldPoint.x, worldPoint.y, worldPoint.z))
        }

        // Calculate and print point cloud bounds (single pass)
        if !points.isEmpty {
            var minP = points[0], maxP = points[0]
            for p in points {
                minP = SIMD3(min(minP.x, p.x), min(minP.y, p.y), min(minP.z, p.z))
                maxP = SIMD3(max(maxP.x, p.x), max(maxP.y, p.y), max(maxP.z, p.z))
            }
            #if DEBUG
            print("[Unproject] Point cloud bounds:")
            print("[Unproject]   X: \(minP.x) to \(maxP.x) (range: \((maxP.x - minP.x) * 100)cm)")
            print("[Unproject]   Y: \(minP.y) to \(maxP.y) (range: \((maxP.y - minP.y) * 100)cm)")
            print("[Unproject]   Z: \(minP.z) to \(maxP.z) (range: \((maxP.z - minP.z) * 100)cm)")
            #endif
        }

        return points
    }

    private func filter3DOutliers(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count > 10 else { return points }

        let centroid = points.reduce(.zero, +) / Float(points.count)

        // Calculate distances from centroid
        let distances = points.map { simd_distance($0, centroid) }

        // MAD-based outlier removal (robust against outliers inflating threshold)
        // Reuse single sorted array for both median and MAD computation
        var sortedDistances = distances.sorted()
        let medianDist = sortedDistances[sortedDistances.count / 2]

        // Compute absolute deviations in-place (reuse sortedDistances array)
        for i in 0..<sortedDistances.count {
            sortedDistances[i] = abs(distances[i] - medianDist)
        }
        sortedDistances.sort()
        let mad = sortedDistances[sortedDistances.count / 2]
        let maxDistance = medianDist + 3.0 * 1.4826 * mad

        return zip(points, distances).compactMap { point, distance in
            distance <= maxDistance ? point : nil
        }
    }

    private func downsample3D(_ points: [SIMD3<Float>], gridSize: Float) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return [] }

        struct GridKey3D: Hashable {
            let x, y, z: Int
        }

        var grid: [GridKey3D: [SIMD3<Float>]] = [:]

        for point in points {
            let key = GridKey3D(x: Int(floor(point.x / gridSize)),
                                y: Int(floor(point.y / gridSize)),
                                z: Int(floor(point.z / gridSize)))
            grid[key, default: []].append(point)
        }

        // Grid centroid downsampling
        return grid.values.map { cellPoints in
            cellPoints.reduce(.zero, +) / Float(cellPoints.count)
        }
    }
}
