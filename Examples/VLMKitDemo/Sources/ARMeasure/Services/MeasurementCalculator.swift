//
//  MeasurementCalculator.swift
//  SnapMeasure
//

import ARKit
import simd
import UIKit

/// Calculates dimensions and volume from bounding boxes
class MeasurementCalculator {
    // MARK: - Types

    struct MeasurementResult {
        let boundingBox: BoundingBox3D
        let length: Float  // meters
        let width: Float   // meters
        let height: Float  // meters
        let volume: Float  // cubic meters
        let quality: MeasurementQuality

        // Axis mapping (fixed at initial measurement time)
        // Determines which local axis (0=x, 1=y, 2=z) corresponds to each dimension
        let heightAxisIndex: Int   // Axis most aligned with world Y (vertical)
        let lengthAxisIndex: Int   // Axis most aligned with camera depth direction
        let widthAxisIndex: Int    // Axis most aligned with camera horizontal direction

        /// Get the axis mapping as a tuple
        var axisMapping: BoundingBox3D.AxisMapping {
            (height: heightAxisIndex, length: lengthAxisIndex, width: widthAxisIndex)
        }

        // Enhanced pipeline: floor Y from nearest horizontal plane
        var detectedFloorY: Float?

        // Point cloud for Fit functionality
        var pointCloud: [SIMD3<Float>]?

        /// Axis-aligned bounding rect of the segmentation mask in raw camera
        /// image (sensor landscape) pixel coordinates, top-left origin. Used to
        /// crop the snapshot tightly around the detected object before sending
        /// it to a downstream consumer (e.g. VLM description). Tighter and more
        /// reliable than projecting the 3D bbox because it's the same pixels
        /// the measurement actually segmented.
        var maskPixelBounds: CGRect?

        // Debug info
        #if DEBUG
        var debugMaskImage: UIImage?
        var debugDepthImage: UIImage?
        var debugPointCloud: [SIMD3<Float>]?
        #endif

        var formattedDimensions: String {
            String(format: "%.1f × %.1f × %.1f cm",
                   length * 100, width * 100, height * 100)
        }

        var formattedVolume: String {
            let volumeCm3 = volume * 1_000_000
            if volumeCm3 >= 1000 {
                return String(format: "%.0f cm³", volumeCm3)
            } else {
                return String(format: "%.1f cm³", volumeCm3)
            }
        }
    }

    // MARK: - Properties

    private let segmentationService = InstanceSegmentationService()
    private let pointCloudGenerator = PointCloudGenerator()
    private let boundingBoxEstimator = BoundingBoxEstimator()

    /// Depth source abstraction (LiDAR or ML fallback)
    var depthSource: DepthSource?

    #if DEBUG
    /// Diagnostics from the last pipeline run (populated on both success and failure)
    private(set) var lastDiagnostics: PipelineDiagnostics?
    /// Captured 3D point clouds at each pipeline stage for visual debugging
    private(set) var lastPointCloudCapture: PipelinePointCloudCapture?
    #endif

    // MARK: - Public Methods

    /// Perform a complete measurement from an AR frame at a tap location
    /// - Parameters:
    ///   - frame: Current AR frame
    ///   - tapPoint: Tap location in view coordinates
    ///   - viewSize: Size of the view
    ///   - mode: Measurement mode
    ///   - raycastHitPosition: 3D world position from ARKit raycast (optional, for filtering)
    /// - Returns: MeasurementResult if successful
    func measure(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> MeasurementResult? {
#if DEBUG
        print("[Calculator] Starting measurement")
        print("[Calculator] Tap point: \(tapPoint), View size: \(viewSize)")
        let diagStartTime = CFAbsoluteTimeGetCurrent()
        let diagnostics = PipelineDiagnostics()
        diagnostics.pipelineVersion = AppConstants.currentPipelineVersion.displayName
#endif

        // Convert tap point to normalized image coordinates (0-1)
        // Note: ARKit camera image is in landscape orientation
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
#if DEBUG
        print("[Calculator] Image size: \(imageSize)")
#endif

        // Convert screen coordinates to image coordinates
        // The AR view displays the camera in portrait, but the pixel buffer is landscape
        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint,
            viewSize: viewSize,
            imageSize: imageSize
        )
#if DEBUG
        print("[Calculator] Normalized tap point: \(normalizedTap)")
        diagnostics.input = PipelineDiagnostics.InputStage(
            tapPoint: tapPoint, normalizedTap: normalizedTap, roi: nil,
            viewSize: viewSize, imageSize: imageSize,
            trackingState: "\(frame.camera.trackingState)",
            mode: "\(mode)", selectionMode: "tap"
        )
#endif

        // 1. Perform instance segmentation
        #if DEBUG
        let segStartTime = CFAbsoluteTimeGetCurrent()
        #endif
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap,
            depthMap: depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        ) else {
#if DEBUG
            print("[Calculator] Segmentation failed - no instance found")
            diagnostics.segmentation = PipelineDiagnostics.SegmentationStage(
                instanceCount: 0, selectedInstance: "none", maskPixelCount: 0,
                maskSize: .zero, durationMs: (CFAbsoluteTimeGetCurrent() - segStartTime) * 1000,
                status: .failed
            )
            diagnostics.failedAtStage = "SEGMENTATION"
            diagnostics.failureReason = "No foreground instance found at tap point"
            diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
            self.lastDiagnostics = diagnostics
#endif
            return nil
        }
#if DEBUG
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")
#endif

        // Offload CPU-heavy processing (depth filter, point cloud, clustering, bbox) off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            #if DEBUG
            diagnostics.segmentation = PipelineDiagnostics.SegmentationStage(
                instanceCount: segmentation.instanceCount,
                selectedInstance: "instance",
                maskPixelCount: 0,  // filled after getMaskedPixels
                maskSize: segmentation.maskSize,
                durationMs: (CFAbsoluteTimeGetCurrent() - segStartTime) * 1000,
                status: .success
            )
            #endif

            // 2. Get masked pixels
            let maskedPixels = segmentationService.getMaskedPixels(
                mask: segmentation.mask,
                imageSize: imageSize
            )

            // Save the raw segmentation footprint in sensor pixel coords so
            // downstream consumers (VLM crop) get the same silhouette the
            // measurement actually saw — guaranteed to enclose the object
            // because it IS the object's mask.
            let maskPixelBounds = Self.boundsOfMaskedPixels(maskedPixels)

            #if DEBUG
            diagnostics.segmentation?.maskPixelCount = maskedPixels.count
            #endif

            guard !maskedPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No masked pixels found")
                diagnostics.failedAtStage = "SEGMENTATION"
                diagnostics.failureReason = "Mask produced zero pixels"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(maskedPixels.count) masked pixels before depth filtering")
#endif

            let pipeline = AppConstants.currentPipelineVersion

            // 2b. Extract 2D connected component around tap point (separate non-touching objects)
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }
            #if DEBUG
            diagnostics.connectedComponent = PipelineDiagnostics.ConnectedComponentStage(
                enabled: pipeline.use2DConnectedComponent,
                pixelsBefore: maskedPixels.count,
                pixelsAfter: ccPixels.count,
                retentionPercent: maskedPixels.count > 0 ? Double(ccPixels.count) / Double(maskedPixels.count) * 100 : 0,
                status: ccPixels.count > 0 ? .success : .warning
            )
            #endif

            // 2c. Refine mask by depth connectivity — separate touching objects
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels,
                    frame: frame,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }
            #if DEBUG
            diagnostics.depthConnectivity = PipelineDiagnostics.DepthConnectivityStage(
                enabled: pipeline.useDepthConnectivity,
                pixelsBefore: ccPixels.count,
                pixelsAfter: connectedPixels.count,
                retentionPercent: ccPixels.count > 0 ? Double(connectedPixels.count) / Double(ccPixels.count) * 100 : 0,
                status: connectedPixels.count > 0 ? .success : .warning
            )
            #endif

            // 3. Filter masked pixels by depth - only keep pixels at similar depth to tap point
            let filteredPixels = filterMaskedPixelsByDepth(
                maskedPixels: connectedPixels,
                frame: frame,
                tapPoint: normalizedTap,
                imageSize: imageSize
            )

            guard !filteredPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No pixels after depth filtering")
                diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                    tapDepth: 0, tolerance: 0, tolerancePercent: 0,
                    pixelsBefore: connectedPixels.count, pixelsAfter: 0,
                    retentionPercent: 0, status: .failed
                )
                diagnostics.failedAtStage = "DEPTH FILTER"
                diagnostics.failureReason = "No pixels remained after depth filtering"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(filteredPixels.count) masked pixels after depth filtering")
            diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                tapDepth: 0, tolerance: 0, tolerancePercent: 0,  // filled by filterMaskedPixelsByDepth prints
                pixelsBefore: connectedPixels.count,
                pixelsAfter: filteredPixels.count,
                retentionPercent: connectedPixels.count > 0 ? Double(filteredPixels.count) / Double(connectedPixels.count) * 100 : 0,
                status: .success
            )
#endif

            // Create debug mask image (memory-optimized version)
            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMask(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                tapPoint: normalizedTap
            )

            // Skip depth image to save memory
            let debugDepthImage: UIImage? = nil
            #endif

            // 4. Generate point cloud from filtered pixels
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame,
                maskedPixels: filteredPixels,
                imageSize: imageSize,
                depthSource: depthSource
            )

            guard !pointCloud.isEmpty else {
#if DEBUG
                print("[Calculator] Point cloud is empty")
                if let gen = pointCloudGenerator.lastGenerationDetails {
                    diagnostics.pointCloud = PipelineDiagnostics.PointCloudStage(
                        inputPixels: gen.inputPixels, extracted: gen.extracted,
                        afterOutlierRemoval: gen.afterOutlierRemoval, afterDownsample: gen.afterDownsample,
                        afterUnproject: gen.afterUnproject, after3DFilter: gen.after3DFilter,
                        finalCount: 0, depthCoverage: 0, depthConfidence: 0, status: .failed
                    )
                }
                diagnostics.failedAtStage = "POINT CLOUD"
                diagnostics.failureReason = "Point cloud generation returned zero points"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")
            if let gen = pointCloudGenerator.lastGenerationDetails {
                diagnostics.pointCloud = PipelineDiagnostics.PointCloudStage(
                    inputPixels: gen.inputPixels, extracted: gen.extracted,
                    afterOutlierRemoval: gen.afterOutlierRemoval, afterDownsample: gen.afterDownsample,
                    afterUnproject: gen.afterUnproject, after3DFilter: gen.after3DFilter,
                    finalCount: gen.finalCount,
                    depthCoverage: pointCloud.quality.depthCoverage,
                    depthConfidence: pointCloud.quality.depthConfidence,
                    status: .success
                )
            }
            // Copy point cloud capture from generator (stages 0-2)
            let pcCapture = pointCloudGenerator.lastPointCloudCapture ?? PipelinePointCloudCapture()
#endif

            // 5. Filter point cloud by 3D distance from raycast hit position
            // This is CRITICAL - if no points are near the tap, the mask is wrong
            if let hitPosition = raycastHitPosition {
                // First check: is the raycast hit anywhere near the point cloud?
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
#if DEBUG
                print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")
#endif

                // If the nearest point is more than 2m away, the mask is completely wrong
                if nearestDistance > 2.0 {
#if DEBUG
                    print("[Calculator] ERROR: Mask does not contain tapped location. Nearest point is \(nearestDistance)m away.")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: 0,
                        pointsAfterProximity: 0, pointsAfterClustering: 0,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Nearest point \(String(format: "%.2f", nearestDistance))m from tap (>2m)"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }

                // Use adaptive radius based on point cloud spread
                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points,
                    center: hitPosition,
                    maxDistance: initialRadius
                )
#if DEBUG
                print("[Calculator] After initial \(initialRadius)m filter: \(filteredPoints.count) points")
                pcCapture.capture(points: filteredPoints, at: .afterProximityFilter)
#endif

                // Use clustering to find the connected object - this separates the tapped object from others
                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                    filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                    print("[Calculator] After clustering: \(filteredPoints.count) points")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "clustering", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif

                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
                    #if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "proximity-only", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
                    #endif
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Calculator] Too few points near tap location (\(filteredPoints.count))")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Too few points near tap (\(filteredPoints.count) < \(fallbackMin))"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }
            } else {
                #if DEBUG
                diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                    nearestDistToHit: 0, proximityRadius: 0,
                    pointsAfterProximity: pointCloud.points.count, pointsAfterClustering: pointCloud.points.count,
                    method: "skipped", status: .skipped
                )
                #endif
            }

            // 6. Estimate bounding box (with vertical plane snap for box mode)
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }

            guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: pointCloud.points,
                mode: mode,
                verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                print("[Calculator] Failed to estimate bounding box")
                diagnostics.bboxEstimation = PipelineDiagnostics.BBoxEstimationStage(
                    hullPointCount: 0, coarseAngleDeg: 0, fineAngleDeg: 0,
                    angleDelta: 0, refinementIterations: 0, method: "unknown", status: .failed
                )
                diagnostics.failedAtStage = "BBOX ESTIMATION"
                diagnostics.failureReason = "Bounding box estimation returned nil"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Bounding box estimated")
            print("[Calculator] Box center: \(boundingBox.center)")
            print("[Calculator] Box extents: \(boundingBox.extents)")
            if let est = boundingBoxEstimator.lastEstimationDetails {
                diagnostics.bboxEstimation = PipelineDiagnostics.BBoxEstimationStage(
                    hullPointCount: est.hullPointCount,
                    coarseAngleDeg: est.coarseAngleDeg,
                    fineAngleDeg: est.fineAngleDeg,
                    angleDelta: abs(est.fineAngleDeg - est.coarseAngleDeg),
                    refinementIterations: est.refinementIterations,
                    method: est.method,
                    status: .success
                )
                diagnostics.planeSnap = PipelineDiagnostics.PlaneSnapStage(
                    snapped: est.snapped,
                    planeCount: est.planeCount,
                    closestDistance: est.closestPlaneDistance,
                    preSnapAngleDeg: est.preSnapAngleDeg,
                    postSnapAngleDeg: est.postSnapAngleDeg,
                    snapDelta: abs(est.postSnapAngleDeg - est.preSnapAngleDeg),
                    score: est.snapScore,
                    method: pipeline.useWeightedPlaneSnap ? "weighted" : "area-only",
                    status: est.snapped ? .success : .skipped
                )
            }
#endif

            // 7. Calculate dimensions using camera-based axis mapping
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
            let volume = boundingBox.volume

#if DEBUG
            print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
            print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
            print("[Calculator] Volume: \(volume * 1_000_000) cm³")
            diagnostics.axisMapping = PipelineDiagnostics.AxisMappingStage(
                heightAxisIndex: mapping.height, lengthAxisIndex: mapping.length, widthAxisIndex: mapping.width,
                heightCm: height * 100, lengthCm: length * 100, widthCm: width * 100
            )
#endif

            var result = MeasurementResult(
                boundingBox: boundingBox,
                length: length,
                width: width,
                height: height,
                volume: volume,
                quality: pointCloud.quality,
                heightAxisIndex: mapping.height,
                lengthAxisIndex: mapping.length,
                widthAxisIndex: mapping.width
            )

            // Store point cloud for Fit functionality
            result.pointCloud = pointCloud.points
            result.maskPixelBounds = maskPixelBounds

            // Detect floor from horizontal plane (current pipelines only)
            if pipeline.useARPlaneFloor {
                result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)
            }
            #if DEBUG
            let boxBottomY = boundingBox.center.y - boundingBox.extents.y
            diagnostics.floor = PipelineDiagnostics.FloorStage(
                detected: result.detectedFloorY != nil,
                floorY: result.detectedFloorY,
                boxBottomY: boxBottomY,
                extensionAmount: result.detectedFloorY.map { boxBottomY - $0 },
                method: pipeline.useARPlaneFloor ? "ARPlane" : "none"
            )
            #endif

            // Attach debug info (images only, not point cloud to save memory)
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            result.debugDepthImage = debugDepthImage
            diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
            self.lastDiagnostics = diagnostics
            self.lastPointCloudCapture = pcCapture
            let stageCounts = PipelinePointCloudCapture.Stage.allCases.map { "\($0.displayName)=\(pcCapture.keptCount(at: $0))" }
            print("[Calculator] Saved point cloud capture: \(stageCounts.joined(separator: ", "))")
            #endif

            return result
        }.value
    }

    /// Perform measurement using a pre-cached segmentation mask (skips Vision segmentation step).
    /// Used when reticle lock-on has already run segmentation in the background.
    func measureWithCachedSegmentation(
        frame: ARFrame,
        cachedMask: CVPixelBuffer,
        cachedMaskSize: CGSize,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> MeasurementResult? {
#if DEBUG
        print("[Calculator] Starting measurement with cached segmentation")
        let diagStartTime = CFAbsoluteTimeGetCurrent()
        let diagnostics = PipelineDiagnostics()
        diagnostics.pipelineVersion = AppConstants.currentPipelineVersion.displayName
#endif

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )

        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint, viewSize: viewSize, imageSize: imageSize
        )

#if DEBUG
        diagnostics.input = PipelineDiagnostics.InputStage(
            tapPoint: tapPoint, normalizedTap: normalizedTap, roi: nil,
            viewSize: viewSize, imageSize: imageSize,
            trackingState: "\(frame.camera.trackingState)",
            mode: "\(mode)", selectionMode: "tap-cached"
        )
        diagnostics.segmentation = PipelineDiagnostics.SegmentationStage(
            instanceCount: 0, selectedInstance: "cached",
            maskPixelCount: 0, maskSize: cachedMaskSize,
            durationMs: 0, status: .success
        )
#endif

        // Use cached mask — skip segmentation entirely
        return await Task.detached(priority: .userInitiated) { [self] in
            let maskedPixels = segmentationService.getMaskedPixels(
                mask: cachedMask, imageSize: imageSize
            )

            // Raw segmentation footprint in sensor pixel coords for VLM crop.
            let maskPixelBounds = Self.boundsOfMaskedPixels(maskedPixels)

            #if DEBUG
            diagnostics.segmentation?.maskPixelCount = maskedPixels.count
            #endif

            guard !maskedPixels.isEmpty else {
#if DEBUG
                diagnostics.failedAtStage = "SEGMENTATION"
                diagnostics.failureReason = "Cached mask produced zero pixels"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }

            let pipeline = AppConstants.currentPipelineVersion

            // 2D connected component
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels, seedPoint: normalizedTap, imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }
            #if DEBUG
            diagnostics.connectedComponent = PipelineDiagnostics.ConnectedComponentStage(
                enabled: pipeline.use2DConnectedComponent,
                pixelsBefore: maskedPixels.count, pixelsAfter: ccPixels.count,
                retentionPercent: maskedPixels.count > 0 ? Double(ccPixels.count) / Double(maskedPixels.count) * 100 : 0,
                status: ccPixels.count > 0 ? .success : .warning
            )
            #endif

            // Depth connectivity
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels, frame: frame, seedPoint: normalizedTap, imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }
            #if DEBUG
            diagnostics.depthConnectivity = PipelineDiagnostics.DepthConnectivityStage(
                enabled: pipeline.useDepthConnectivity,
                pixelsBefore: ccPixels.count, pixelsAfter: connectedPixels.count,
                retentionPercent: ccPixels.count > 0 ? Double(connectedPixels.count) / Double(ccPixels.count) * 100 : 0,
                status: connectedPixels.count > 0 ? .success : .warning
            )
            #endif

            // Depth filter
            let filteredPixels = filterMaskedPixelsByDepth(
                maskedPixels: connectedPixels, frame: frame, tapPoint: normalizedTap, imageSize: imageSize
            )
            guard !filteredPixels.isEmpty else {
#if DEBUG
                diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                    tapDepth: 0, tolerance: 0, tolerancePercent: 0,
                    pixelsBefore: connectedPixels.count, pixelsAfter: 0,
                    retentionPercent: 0, status: .failed
                )
                diagnostics.failedAtStage = "DEPTH FILTER"
                diagnostics.failureReason = "No pixels remained after depth filtering"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                tapDepth: 0, tolerance: 0, tolerancePercent: 0,
                pixelsBefore: connectedPixels.count, pixelsAfter: filteredPixels.count,
                retentionPercent: connectedPixels.count > 0 ? Double(filteredPixels.count) / Double(connectedPixels.count) * 100 : 0,
                status: .success
            )
            let debugMaskImage: UIImage? = nil
#endif

            // Point cloud generation
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame, maskedPixels: filteredPixels, imageSize: imageSize,
                depthSource: depthSource
            )
            guard !pointCloud.isEmpty else {
#if DEBUG
                diagnostics.failedAtStage = "POINT CLOUD"
                diagnostics.failureReason = "Point cloud generation returned zero points"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            if let gen = pointCloudGenerator.lastGenerationDetails {
                diagnostics.pointCloud = PipelineDiagnostics.PointCloudStage(
                    inputPixels: gen.inputPixels, extracted: gen.extracted,
                    afterOutlierRemoval: gen.afterOutlierRemoval, afterDownsample: gen.afterDownsample,
                    afterUnproject: gen.afterUnproject, after3DFilter: gen.after3DFilter,
                    finalCount: gen.finalCount,
                    depthCoverage: pointCloud.quality.depthCoverage,
                    depthConfidence: pointCloud.quality.depthConfidence,
                    status: .success
                )
            }
            let pcCapture = pointCloudGenerator.lastPointCloudCapture ?? PipelinePointCloudCapture()
#endif

            // Proximity filter + clustering
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
                if nearestDistance > 2.0 {
#if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: 0,
                        pointsAfterProximity: 0, pointsAfterClustering: 0,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Nearest point \(String(format: "%.2f", nearestDistance))m from tap (>2m)"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }

                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points, center: hitPosition, maxDistance: initialRadius
                )
#if DEBUG
                pcCapture.capture(points: filteredPoints, at: .afterProximityFilter)
#endif

                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                    filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "clustering", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif
                    pointCloud = PointCloudGenerator.PointCloud(points: filteredPoints, quality: pointCloud.quality)
                } else if filteredPoints.count >= fallbackMin {
#if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "proximity-only", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif
                    pointCloud = PointCloudGenerator.PointCloud(points: filteredPoints, quality: pointCloud.quality)
                } else {
#if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Too few points near tap (\(filteredPoints.count) < \(fallbackMin))"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }
            } else {
#if DEBUG
                diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                    nearestDistToHit: 0, proximityRadius: 0,
                    pointsAfterProximity: pointCloud.points.count, pointsAfterClustering: pointCloud.points.count,
                    method: "skipped", status: .skipped
                )
#endif
            }

            // Bounding box estimation
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }
            guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: pointCloud.points, mode: mode, verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                diagnostics.failedAtStage = "BBOX ESTIMATION"
                diagnostics.failureReason = "Bounding box estimation returned nil"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            if let est = boundingBoxEstimator.lastEstimationDetails {
                diagnostics.bboxEstimation = PipelineDiagnostics.BBoxEstimationStage(
                    hullPointCount: est.hullPointCount, coarseAngleDeg: est.coarseAngleDeg,
                    fineAngleDeg: est.fineAngleDeg,
                    angleDelta: abs(est.fineAngleDeg - est.coarseAngleDeg),
                    refinementIterations: est.refinementIterations, method: est.method, status: .success
                )
                diagnostics.planeSnap = PipelineDiagnostics.PlaneSnapStage(
                    snapped: est.snapped, planeCount: est.planeCount,
                    closestDistance: est.closestPlaneDistance,
                    preSnapAngleDeg: est.preSnapAngleDeg, postSnapAngleDeg: est.postSnapAngleDeg,
                    snapDelta: abs(est.postSnapAngleDeg - est.preSnapAngleDeg),
                    score: est.snapScore,
                    method: pipeline.useWeightedPlaneSnap ? "weighted" : "area-only",
                    status: est.snapped ? .success : .skipped
                )
            }
#endif

            // Calculate dimensions
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)

#if DEBUG
            diagnostics.axisMapping = PipelineDiagnostics.AxisMappingStage(
                heightAxisIndex: mapping.height, lengthAxisIndex: mapping.length, widthAxisIndex: mapping.width,
                heightCm: height * 100, lengthCm: length * 100, widthCm: width * 100
            )
#endif

            var result = MeasurementResult(
                boundingBox: boundingBox,
                length: length, width: width, height: height,
                volume: boundingBox.volume,
                quality: pointCloud.quality,
                heightAxisIndex: mapping.height,
                lengthAxisIndex: mapping.length,
                widthAxisIndex: mapping.width
            )
            result.pointCloud = pointCloud.points
            result.maskPixelBounds = maskPixelBounds

            if pipeline.useARPlaneFloor {
                result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)
            }
#if DEBUG
            let boxBottomY = boundingBox.center.y - boundingBox.extents.y
            diagnostics.floor = PipelineDiagnostics.FloorStage(
                detected: result.detectedFloorY != nil,
                floorY: result.detectedFloorY, boxBottomY: boxBottomY,
                extensionAmount: result.detectedFloorY.map { boxBottomY - $0 },
                method: pipeline.useARPlaneFloor ? "ARPlane" : "none"
            )
            result.debugMaskImage = debugMaskImage
            diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
            self.lastDiagnostics = diagnostics
            self.lastPointCloudCapture = pcCapture
            print("[Calculator] Cached seg measurement complete in \(String(format: "%.0f", diagnostics.overallDurationMs))ms")
#endif

            return result
        }.value
    }

    /// Perform measurement within a specific region of interest (box selection mode)
    /// - Parameters:
    ///   - frame: Current AR frame
    ///   - regionOfInterest: Screen rect defining the selection box
    ///   - viewSize: Size of the view
    ///   - mode: Measurement mode
    ///   - raycastHitPosition: 3D world position from ARKit raycast (optional)
    /// - Returns: MeasurementResult if successful
    func measureWithROI(
        frame: ARFrame,
        regionOfInterest: CGRect,
        viewSize: CGSize,
        mode: MeasurementMode,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> MeasurementResult? {
#if DEBUG
        print("[Calculator] Starting ROI measurement")
        print("[Calculator] Screen ROI: \(regionOfInterest), View size: \(viewSize)")
        let diagStartTime = CFAbsoluteTimeGetCurrent()
        let diagnostics = PipelineDiagnostics()
        diagnostics.pipelineVersion = AppConstants.currentPipelineVersion.displayName
#endif

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
#if DEBUG
        print("[Calculator] Image size: \(imageSize)")
#endif

        // Convert screen ROI to Vision normalized coordinates
        let visionROI = convertScreenRectToVisionCoordinates(
            screenRect: regionOfInterest,
            viewSize: viewSize
        )
#if DEBUG
        print("[Calculator] Vision ROI: \(visionROI)")
        diagnostics.input = PipelineDiagnostics.InputStage(
            tapPoint: nil, normalizedTap: nil, roi: regionOfInterest,
            viewSize: viewSize, imageSize: imageSize,
            trackingState: "\(frame.camera.trackingState)",
            mode: "\(mode)", selectionMode: "box"
        )
#endif

        // 1. Perform instance segmentation with ROI
        #if DEBUG
        let segStartTime = CFAbsoluteTimeGetCurrent()
        #endif
        guard let segmentation = try await segmentationService.segmentInstanceWithROI(
            in: frame.capturedImage,
            regionOfInterest: visionROI
        ) else {
#if DEBUG
            print("[Calculator] Segmentation with ROI failed - no instance found")
            diagnostics.segmentation = PipelineDiagnostics.SegmentationStage(
                instanceCount: 0, selectedInstance: "none", maskPixelCount: 0,
                maskSize: .zero, durationMs: (CFAbsoluteTimeGetCurrent() - segStartTime) * 1000,
                status: .failed
            )
            diagnostics.failedAtStage = "SEGMENTATION"
            diagnostics.failureReason = "No foreground instance found in ROI"
            diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
            self.lastDiagnostics = diagnostics
#endif
            return nil
        }
#if DEBUG
        print("[Calculator] Segmentation successful, mask size: \(segmentation.maskSize)")
#endif

        // Pre-compute normalized center on calling thread (cheap)
        let boxCenter = CGPoint(x: regionOfInterest.midX, y: regionOfInterest.midY)
        let normalizedCenter = convertScreenToImageCoordinates(
            screenPoint: boxCenter,
            viewSize: viewSize,
            imageSize: imageSize
        )

        // Offload CPU-heavy processing off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            #if DEBUG
            diagnostics.segmentation = PipelineDiagnostics.SegmentationStage(
                instanceCount: segmentation.instanceCount,
                selectedInstance: "ROI",
                maskPixelCount: 0,
                maskSize: segmentation.maskSize,
                durationMs: (CFAbsoluteTimeGetCurrent() - segStartTime) * 1000,
                status: .success
            )
            #endif

            // 2. Get masked pixels with ROI coordinate transformation
            let maskedPixels = segmentationService.getMaskedPixelsWithROI(
                mask: segmentation.mask,
                imageSize: imageSize,
                visionROI: visionROI
            )

            // Raw segmentation footprint in sensor pixel coords for VLM crop.
            let maskPixelBounds = Self.boundsOfMaskedPixels(maskedPixels)

            #if DEBUG
            diagnostics.segmentation?.maskPixelCount = maskedPixels.count
            #endif

            guard !maskedPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No masked pixels found")
                diagnostics.failedAtStage = "SEGMENTATION"
                diagnostics.failureReason = "Mask produced zero pixels"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(maskedPixels.count) masked pixels")
#endif

            let pipeline = AppConstants.currentPipelineVersion

            // 3b. Extract 2D connected component around box center
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedCenter,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }
            #if DEBUG
            diagnostics.connectedComponent = PipelineDiagnostics.ConnectedComponentStage(
                enabled: pipeline.use2DConnectedComponent,
                pixelsBefore: maskedPixels.count, pixelsAfter: ccPixels.count,
                retentionPercent: maskedPixels.count > 0 ? Double(ccPixels.count) / Double(maskedPixels.count) * 100 : 0,
                status: ccPixels.count > 0 ? .success : .warning
            )
            #endif

            // 3c. Refine mask by depth connectivity — separate touching objects
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels,
                    frame: frame,
                    seedPoint: normalizedCenter,
                    imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }
            #if DEBUG
            diagnostics.depthConnectivity = PipelineDiagnostics.DepthConnectivityStage(
                enabled: pipeline.useDepthConnectivity,
                pixelsBefore: ccPixels.count, pixelsAfter: connectedPixels.count,
                retentionPercent: ccPixels.count > 0 ? Double(connectedPixels.count) / Double(ccPixels.count) * 100 : 0,
                status: connectedPixels.count > 0 ? .success : .warning
            )
            #endif

            // 4. Apply depth filtering based on box center
            let depthFilteredPixels = filterMaskedPixelsByDepth(
                maskedPixels: connectedPixels,
                frame: frame,
                tapPoint: normalizedCenter,
                imageSize: imageSize
            )

            guard !depthFilteredPixels.isEmpty else {
#if DEBUG
                print("[Calculator] No pixels after depth filtering")
                diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                    tapDepth: 0, tolerance: 0, tolerancePercent: 0,
                    pixelsBefore: connectedPixels.count, pixelsAfter: 0,
                    retentionPercent: 0, status: .failed
                )
                diagnostics.failedAtStage = "DEPTH FILTER"
                diagnostics.failureReason = "No pixels remained after depth filtering"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Found \(depthFilteredPixels.count) masked pixels after depth filtering")
            diagnostics.depthFilter = PipelineDiagnostics.DepthFilterStage(
                tapDepth: 0, tolerance: 0, tolerancePercent: 0,
                pixelsBefore: connectedPixels.count, pixelsAfter: depthFilteredPixels.count,
                retentionPercent: connectedPixels.count > 0 ? Double(depthFilteredPixels.count) / Double(connectedPixels.count) * 100 : 0,
                status: .success
            )
#endif

            // Create debug mask image with ROI
            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMaskWithROI(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                visionROI: visionROI,
                screenRect: regionOfInterest,
                viewSize: viewSize,
                tapPoint: normalizedCenter
            )
            #endif

            // 5. Generate point cloud
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame,
                maskedPixels: depthFilteredPixels,
                imageSize: imageSize,
                depthSource: depthSource
            )

            guard !pointCloud.isEmpty else {
#if DEBUG
                print("[Calculator] Point cloud is empty")
                diagnostics.failedAtStage = "POINT CLOUD"
                diagnostics.failureReason = "Point cloud generation returned zero points"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Generated point cloud with \(pointCloud.points.count) points")
            if let gen = pointCloudGenerator.lastGenerationDetails {
                diagnostics.pointCloud = PipelineDiagnostics.PointCloudStage(
                    inputPixels: gen.inputPixels, extracted: gen.extracted,
                    afterOutlierRemoval: gen.afterOutlierRemoval, afterDownsample: gen.afterDownsample,
                    afterUnproject: gen.afterUnproject, after3DFilter: gen.after3DFilter,
                    finalCount: gen.finalCount,
                    depthCoverage: pointCloud.quality.depthCoverage,
                    depthConfidence: pointCloud.quality.depthConfidence,
                    status: .success
                )
            }
            // Copy point cloud capture from generator (stages 0-2)
            let pcCapture = pointCloudGenerator.lastPointCloudCapture ?? PipelinePointCloudCapture()
#endif

            // 6. Filter by proximity if raycast hit available
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
#if DEBUG
                print("[Calculator] Nearest point cloud distance to raycast hit: \(nearestDistance)m")
#endif

                if nearestDistance > 2.0 {
#if DEBUG
                    print("[Calculator] ERROR: Point cloud too far from raycast hit")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: 0,
                        pointsAfterProximity: 0, pointsAfterClustering: 0,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Point cloud too far from raycast hit"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }

                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points,
                    center: hitPosition,
                    maxDistance: initialRadius
                )
#if DEBUG
                print("[Calculator] After initial \(initialRadius)m filter: \(filteredPoints.count) points")
                pcCapture.capture(points: filteredPoints, at: .afterProximityFilter)
#endif

                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                    filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                    print("[Calculator] After clustering: \(filteredPoints.count) points")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "clustering", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif

                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
                    #if DEBUG
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "proximity-only", status: .success
                    )
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
                    #endif
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints,
                        quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Calculator] Too few points near box center (\(filteredPoints.count))")
                    diagnostics.clustering = PipelineDiagnostics.ClusteringStage(
                        nearestDistToHit: nearestDistance, proximityRadius: initialRadius,
                        pointsAfterProximity: filteredPoints.count, pointsAfterClustering: filteredPoints.count,
                        method: "rejected", status: .failed
                    )
                    diagnostics.failedAtStage = "CLUSTERING"
                    diagnostics.failureReason = "Too few points near box center (\(filteredPoints.count))"
                    diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                    self.lastDiagnostics = diagnostics
#endif
                    return nil
                }
            }

            // 7. Estimate bounding box (with vertical plane snap for box mode)
            let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                return plane
            }

            guard let boundingBox = boundingBoxEstimator.estimateBoundingBox(
                points: pointCloud.points,
                mode: mode,
                verticalPlaneAnchors: verticalPlanes
            ) else {
#if DEBUG
                print("[Calculator] Failed to estimate bounding box")
                diagnostics.failedAtStage = "BBOX ESTIMATION"
                diagnostics.failureReason = "Bounding box estimation returned nil"
                diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
                self.lastDiagnostics = diagnostics
#endif
                return nil
            }
#if DEBUG
            print("[Calculator] Bounding box estimated")
            if let est = boundingBoxEstimator.lastEstimationDetails {
                diagnostics.bboxEstimation = PipelineDiagnostics.BBoxEstimationStage(
                    hullPointCount: est.hullPointCount, coarseAngleDeg: est.coarseAngleDeg,
                    fineAngleDeg: est.fineAngleDeg,
                    angleDelta: abs(est.fineAngleDeg - est.coarseAngleDeg),
                    refinementIterations: est.refinementIterations, method: est.method,
                    status: .success
                )
                diagnostics.planeSnap = PipelineDiagnostics.PlaneSnapStage(
                    snapped: est.snapped, planeCount: est.planeCount,
                    closestDistance: est.closestPlaneDistance,
                    preSnapAngleDeg: est.preSnapAngleDeg, postSnapAngleDeg: est.postSnapAngleDeg,
                    snapDelta: abs(est.postSnapAngleDeg - est.preSnapAngleDeg),
                    score: est.snapScore,
                    method: pipeline.useWeightedPlaneSnap ? "weighted" : "area-only",
                    status: est.snapped ? .success : .skipped
                )
            }
#endif

            // 8. Calculate dimensions using camera-based axis mapping
            let mapping = boundingBox.calculateAxisMapping(cameraTransform: frame.camera.transform)
            let (height, length, width) = boundingBox.dimensions(withMapping: mapping)
            let volume = boundingBox.volume

#if DEBUG
            print("[Calculator] Axis mapping: height=\(mapping.height), length=\(mapping.length), width=\(mapping.width)")
            print("[Calculator] Dimensions: L=\(length*100)cm, W=\(width*100)cm, H=\(height*100)cm")
            diagnostics.axisMapping = PipelineDiagnostics.AxisMappingStage(
                heightAxisIndex: mapping.height, lengthAxisIndex: mapping.length, widthAxisIndex: mapping.width,
                heightCm: height * 100, lengthCm: length * 100, widthCm: width * 100
            )
#endif

            var result = MeasurementResult(
                boundingBox: boundingBox,
                length: length,
                width: width,
                height: height,
                volume: volume,
                quality: pointCloud.quality,
                heightAxisIndex: mapping.height,
                lengthAxisIndex: mapping.length,
                widthAxisIndex: mapping.width
            )

            result.pointCloud = pointCloud.points
            result.maskPixelBounds = maskPixelBounds
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            #endif

            // Detect floor from horizontal plane (current pipelines only)
            if pipeline.useARPlaneFloor {
                result.detectedFloorY = Self.detectHorizontalPlaneFloorY(frame: frame, nearPoint: boundingBox.center)
            }
            #if DEBUG
            let boxBottomY = boundingBox.center.y - boundingBox.extents.y
            diagnostics.floor = PipelineDiagnostics.FloorStage(
                detected: result.detectedFloorY != nil,
                floorY: result.detectedFloorY, boxBottomY: boxBottomY,
                extensionAmount: result.detectedFloorY.map { boxBottomY - $0 },
                method: pipeline.useARPlaneFloor ? "ARPlane" : "none"
            )
            diagnostics.overallDurationMs = (CFAbsoluteTimeGetCurrent() - diagStartTime) * 1000
            self.lastDiagnostics = diagnostics
            self.lastPointCloudCapture = pcCapture
            let stageCounts = PipelinePointCloudCapture.Stage.allCases.map { "\($0.displayName)=\(pcCapture.keptCount(at: $0))" }
            print("[Calculator] Saved ROI point cloud capture: \(stageCounts.joined(separator: ", "))")
            #endif

            return result
        }.value
    }

    /// Convert screen rectangle to Vision normalized coordinates
    /// Vision uses bottom-left origin (0-1 range)
    /// Axis-aligned bounding rect of a `[(x, y)]` pixel set, in the same
    /// coord space as the inputs. Returns `nil` for an empty set.
    private static func boundsOfMaskedPixels(_ pixels: [(x: Int, y: Int)]) -> CGRect? {
        guard let first = pixels.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in pixels {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func convertScreenRectToVisionCoordinates(
        screenRect: CGRect,
        viewSize: CGSize
    ) -> CGRect {
        // Screen coordinate system: top-left origin, portrait
        // Vision coordinate system: bottom-left origin, normalized (0-1)
        // Camera image is landscape, display is portrait (90° CCW rotation)
        //
        // Screen point (sx, sy) → Vision point (vx, vy):
        // - Screen Y maps to Vision X: vx = sy / screenHeight
        // - Screen X maps to Vision Y: vy = sx / screenWidth
        //
        // For rectangle (origin at top-left corner in screen coords):
        // - Vision origin.x = screen minY / screenHeight
        // - Vision origin.y = screen minX / screenWidth
        // - Vision width = screen height / screenHeight
        // - Vision height = screen width / screenWidth

        let normalizedX = screenRect.minY / viewSize.height
        let normalizedY = screenRect.minX / viewSize.width
        let normalizedWidth = screenRect.height / viewSize.height
        let normalizedHeight = screenRect.width / viewSize.width

#if DEBUG
        print("[Coords] Screen rect: \(screenRect)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Vision ROI: x=\(normalizedX), y=\(normalizedY), w=\(normalizedWidth), h=\(normalizedHeight)")
#endif

        return CGRect(
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    /// Filter pixels to only include those within the screen ROI
    private func filterPixelsToROI(
        pixels: [(x: Int, y: Int)],
        screenRect: CGRect,
        viewSize: CGSize,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        // Convert screen ROI to image pixel coordinates
        // Screen (portrait, top-left origin) → Image (landscape, top-left origin)
        //
        // Screen point (sx, sy) → Image point (ix, iy):
        // - ix = sy / screenHeight * imageWidth
        // - iy = sx / screenWidth * imageHeight
        //
        // Note: Image Y increases downward, but screen X→image Y mapping
        // means screen left→image top, screen right→image bottom

        let imageMinX = Int(screenRect.minY / viewSize.height * imageSize.width)
        let imageMaxX = Int(screenRect.maxY / viewSize.height * imageSize.width)
        let imageMinY = Int(screenRect.minX / viewSize.width * imageSize.height)
        let imageMaxY = Int(screenRect.maxX / viewSize.width * imageSize.height)

#if DEBUG
        print("[ROIFilter] Image ROI bounds: x=\(imageMinX)-\(imageMaxX), y=\(imageMinY)-\(imageMaxY)")
#endif

        var filtered: [(x: Int, y: Int)] = []
        filtered.reserveCapacity(pixels.count)

        for pixel in pixels {
            if pixel.x >= imageMinX && pixel.x <= imageMaxX &&
               pixel.y >= imageMinY && pixel.y <= imageMaxY {
                filtered.append(pixel)
            }
        }

#if DEBUG
        print("[ROIFilter] Filtered from \(pixels.count) to \(filtered.count) pixels")
#endif
        return filtered
    }

    /// Convert screen coordinates to normalized image coordinates
    private func convertScreenToImageCoordinates(
        screenPoint: CGPoint,
        viewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        // The camera image is captured in landscape orientation
        // ARView displays it rotated 90° CCW to fit portrait
        //
        // Mapping (determined empirically):
        // - screenY/screenHeight → normalizedImageX (top=0, bottom=1)
        // - 1 - screenX/screenWidth → normalizedImageY (left=1, right=0)

        let normalizedX = screenPoint.y / viewSize.height
        let normalizedY = 1.0 - (screenPoint.x / viewSize.width)

#if DEBUG
        print("[Coords] Screen point: \(screenPoint)")
        print("[Coords] View size: \(viewSize)")
        print("[Coords] Image size: \(imageSize)")
        print("[Coords] Normalized tap (landscape image): (\(normalizedX), \(normalizedY))")
        print("[Coords] Image pixel: (\(normalizedX * imageSize.width), \(normalizedY * imageSize.height))")
#endif

        return CGPoint(x: normalizedX, y: normalizedY)
    }

    /// Update measurement with an edited bounding box, preserving the original axis mapping
    /// - Parameters:
    ///   - boundingBox: The modified bounding box
    ///   - quality: The measurement quality
    ///   - axisMapping: The original axis mapping from the initial measurement
    /// - Returns: Updated MeasurementResult with recalculated dimensions
    func recalculate(
        boundingBox: BoundingBox3D,
        quality: MeasurementQuality,
        axisMapping: BoundingBox3D.AxisMapping
    ) -> MeasurementResult {
        let (height, length, width) = boundingBox.dimensions(withMapping: axisMapping)

        return MeasurementResult(
            boundingBox: boundingBox,
            length: length,
            width: width,
            height: height,
            volume: boundingBox.volume,
            quality: quality,
            heightAxisIndex: axisMapping.height,
            lengthAxisIndex: axisMapping.length,
            widthAxisIndex: axisMapping.width
        )
    }

    // MARK: - Refinement

    /// Point cloud captured from a refinement angle
    struct RefinementPointCloud {
        let points: [SIMD3<Float>]
        let quality: MeasurementQuality
        #if DEBUG
        var debugMaskImage: UIImage?
        #endif
    }

    /// Perform a refinement measurement: segment + point cloud only (no bounding box estimation).
    /// Validates that the new point cloud overlaps the existing bounding box.
    func measureForRefinement(
        frame: ARFrame,
        tapPoint: CGPoint,
        viewSize: CGSize,
        mode: MeasurementMode,
        existingBox: BoundingBox3D,
        raycastHitPosition: SIMD3<Float>? = nil
    ) async throws -> RefinementPointCloud? {
#if DEBUG
        print("[Refine] Starting refinement measurement")
#endif

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )

        let normalizedTap = convertScreenToImageCoordinates(
            screenPoint: tapPoint, viewSize: viewSize, imageSize: imageSize
        )

        // 1. Segmentation
        guard let segmentation = try await segmentationService.segmentInstance(
            in: frame.capturedImage,
            at: normalizedTap,
            depthMap: depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        ) else {
#if DEBUG
            print("[Refine] Segmentation failed")
#endif
            return nil
        }

        // Offload CPU-heavy processing off main thread
        return await Task.detached(priority: .userInitiated) { [self] in
            // 2. Masked pixels
            let maskedPixels = segmentationService.getMaskedPixels(
                mask: segmentation.mask, imageSize: imageSize
            )
            guard !maskedPixels.isEmpty else { return nil }

            #if DEBUG
            let debugMaskImage = DebugVisualization.visualizeMask(
                mask: segmentation.mask,
                cameraImage: frame.capturedImage,
                tapPoint: normalizedTap
            )
            #endif

            let pipeline = AppConstants.currentPipelineVersion

            // 2b. Extract 2D connected component around tap point
            let ccPixels: [(x: Int, y: Int)]
            if pipeline.use2DConnectedComponent {
                ccPixels = extractConnectedComponent(
                    maskedPixels: maskedPixels,
                    seedPoint: normalizedTap,
                    imageSize: imageSize
                )
            } else {
                ccPixels = maskedPixels
            }

            // 2c. Refine mask by depth connectivity
            let connectedPixels: [(x: Int, y: Int)]
            if pipeline.useDepthConnectivity {
                connectedPixels = refineMaskedPixelsByDepthConnectivity(
                    maskedPixels: ccPixels, frame: frame,
                    seedPoint: normalizedTap, imageSize: imageSize
                )
            } else {
                connectedPixels = ccPixels
            }

            // 3. Depth filtering
            let filteredPixels = filterMaskedPixelsByDepth(
                maskedPixels: connectedPixels, frame: frame,
                tapPoint: normalizedTap, imageSize: imageSize
            )
            guard !filteredPixels.isEmpty else { return nil }

            // 4. Point cloud generation
            var pointCloud = pointCloudGenerator.generatePointCloud(
                frame: frame, maskedPixels: filteredPixels, imageSize: imageSize,
                depthSource: depthSource
            )
            guard !pointCloud.isEmpty else { return nil }
#if DEBUG
            print("[Refine] Generated \(pointCloud.points.count) points")
            let pcCapture = pointCloudGenerator.lastPointCloudCapture ?? PipelinePointCloudCapture()
#endif

            // 5. Proximity filter + clustering (same as measure())
            if let hitPosition = raycastHitPosition {
                var nearestDistance: Float = .infinity
                for p in pointCloud.points {
                    nearestDistance = min(nearestDistance, simd_distance(p, hitPosition))
                }
                if nearestDistance > 2.0 { return nil }

                let pointSpread = Self.estimatePointSpread(points: pointCloud.points)
                let initialRadius: Float = max(pipeline.proximityMinRadius, pointSpread * pipeline.proximitySpreadScale)
                var filteredPoints = filterPointsByProximity(
                    points: pointCloud.points, center: hitPosition, maxDistance: initialRadius
                )
#if DEBUG
                pcCapture.capture(points: filteredPoints, at: .afterProximityFilter)
#endif

                let clusterMin = pipeline.clusteringMinPoints
                let fallbackMin = pipeline.clusteringFallbackMinPoints
                if filteredPoints.count >= clusterMin {
                    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                    filteredPoints = extractMainCluster(points: filteredPoints, center: hitPosition, cameraPosition: camPos)
#if DEBUG
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints, quality: pointCloud.quality
                    )
                } else if filteredPoints.count >= fallbackMin {
#if DEBUG
                    pcCapture.capture(points: filteredPoints, at: .afterClustering)
#endif
                    pointCloud = PointCloudGenerator.PointCloud(
                        points: filteredPoints, quality: pointCloud.quality
                    )
                } else {
#if DEBUG
                    print("[Refine] Too few points near tap (\(filteredPoints.count))")
#endif
                    return nil
                }
            }

            // 6. Same-object validation: check overlap with expanded existing box
            let expandedBox = Self.expandedBoundingBox(existingBox, scale: AppConstants.refinementProximityScale)
            let insideCount = pointCloud.points.filter { expandedBox.contains($0) }.count
            let overlapRatio = Float(insideCount) / Float(pointCloud.points.count)
#if DEBUG
            print("[Refine] Overlap ratio: \(overlapRatio) (\(insideCount)/\(pointCloud.points.count))")
#endif

            guard overlapRatio >= AppConstants.refinementOverlapThreshold else {
#if DEBUG
                print("[Refine] Overlap too low – object not matched")
#endif
                return nil
            }

            var result = RefinementPointCloud(points: pointCloud.points, quality: pointCloud.quality)
            #if DEBUG
            result.debugMaskImage = debugMaskImage
            self.lastPointCloudCapture = pcCapture
            print("[Refine] Saved point cloud capture")
            #endif
            return result
        }.value
    }

    /// Expand a bounding box by scaling its extents
    static func expandedBoundingBox(_ box: BoundingBox3D, scale: Float) -> BoundingBox3D {
        var expanded = box
        expanded.extents = box.extents * scale
        return expanded
    }

    /// Calculate dimensions from a bounding box
    static func calculateDimensions(from box: BoundingBox3D) -> (length: Float, width: Float, height: Float) {
        let sorted = box.sortedDimensions
        return (sorted[0].dimension, sorted[1].dimension, sorted[2].dimension)
    }

    /// Filter masked pixels to only include those at similar depth to the tap point
    private func filterMaskedPixelsByDepth(
        maskedPixels: [(x: Int, y: Int)],
        frame: ARFrame,
        tapPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard let depthMap = depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
#if DEBUG
            print("[DepthFilter] No depth map available, returning all pixels")
#endif
            return maskedPixels
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return maskedPixels
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

        // Scale factors from image to depth coordinates
        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        // Get depth at tap point
        let tapDepthX = Int(tapPoint.x * imageSize.width * scaleX)
        let tapDepthY = Int(tapPoint.y * imageSize.height * scaleY)

        guard tapDepthX >= 0 && tapDepthX < depthWidth && tapDepthY >= 0 && tapDepthY < depthHeight else {
#if DEBUG
            print("[DepthFilter] Tap point out of depth map bounds")
#endif
            return maskedPixels
        }

        let tapDepthIndex = tapDepthY * (depthBytesPerRow / MemoryLayout<Float32>.size) + tapDepthX
        let tapDepth = depthPtr[tapDepthIndex]

#if DEBUG
        print("[DepthFilter] Tap depth: \(tapDepth)m at depth pixel (\(tapDepthX), \(tapDepthY))")
#endif

        guard tapDepth.isFinite && tapDepth > 0 else {
#if DEBUG
            print("[DepthFilter] Invalid tap depth, returning all pixels")
#endif
            return maskedPixels
        }

        let pipeline = AppConstants.currentPipelineVersion
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        // Adaptive depth filter: IQR-based range intersected with tap-based range
        if pipeline.useAdaptiveDepthFilter {
            return filterAdaptiveDepth(
                maskedPixels: maskedPixels,
                depthPtr: depthPtr,
                depthStride: depthStride,
                depthWidth: depthWidth,
                depthHeight: depthHeight,
                scaleX: scaleX,
                scaleY: scaleY,
                tapDepth: tapDepth,
                pipeline: pipeline
            )
        }

        // Legacy fixed-tolerance depth filter
        let percentTolerance = tapDepth * pipeline.depthFilterPercent
        let depthTolerance: Float
        if let maxTol = pipeline.depthFilterMax {
            depthTolerance = min(max(percentTolerance, pipeline.depthFilterMin), maxTol)
        } else {
            depthTolerance = max(percentTolerance, pipeline.depthFilterMin)  // v1: no max clamp
        }

#if DEBUG
        print("[DepthFilter] Depth tolerance: ±\(depthTolerance)m (percent=\(pipeline.depthFilterPercent), min=\(pipeline.depthFilterMin), max=\(pipeline.depthFilterMax as Any))")
#endif

        var filteredPixels: [(x: Int, y: Int)] = []
        filteredPixels.reserveCapacity(maskedPixels.count / 2)

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)

            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }

            let depthIndex = depthY * depthStride + depthX
            let pixelDepth = depthPtr[depthIndex]

            if pixelDepth.isFinite && pixelDepth > 0 {
                let depthDiff = abs(pixelDepth - tapDepth)
                if depthDiff <= depthTolerance {
                    filteredPixels.append(pixel)
                }
            }
        }

#if DEBUG
        print("[DepthFilter] Filtered from \(maskedPixels.count) to \(filteredPixels.count) pixels")
#endif

        // Safety valve: behavior differs by pipeline version
        if pipeline.depthFilterReturnsOriginalOnTooFew {
            // Legacy: if too few pass filter, return original pixels
            if filteredPixels.count < 100 {
#if DEBUG
                print("[DepthFilter] Too few pixels after filtering (\(filteredPixels.count) < 100), returning original \(maskedPixels.count) pixels")
#endif
                return maskedPixels
            }
        } else {
            // Current: proportional minimum, return empty on failure
            let minRequired = max(20, maskedPixels.count / 20)
            if filteredPixels.count < minRequired {
#if DEBUG
                print("[DepthFilter] Too few pixels after filtering (\(filteredPixels.count) < \(minRequired)), returning empty")
#endif
                return []
            }
        }

        return filteredPixels
    }

    /// Adaptive depth filter using IQR-based outlier detection intersected with tap-based range.
    /// Replaces the fixed max-clamp approach for standard/enhanced pipelines.
    private func filterAdaptiveDepth(
        maskedPixels: [(x: Int, y: Int)],
        depthPtr: UnsafePointer<Float32>,
        depthStride: Int,
        depthWidth: Int,
        depthHeight: Int,
        scaleX: CGFloat,
        scaleY: CGFloat,
        tapDepth: Float,
        pipeline: PipelineVersion
    ) -> [(x: Int, y: Int)] {
        // Pass 1: Collect valid depths from masked pixels
        var depths: [Float] = []
        depths.reserveCapacity(maskedPixels.count)

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)
            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }
            let pixelDepth = depthPtr[depthY * depthStride + depthX]
            if pixelDepth.isFinite && pixelDepth > 0 {
                depths.append(pixelDepth)
            }
        }

        guard depths.count >= 10 else {
#if DEBUG
            print("[DepthFilter] Adaptive: too few valid depths (\(depths.count)), returning empty")
#endif
            return []
        }

        // Sort and compute IQR
        depths.sort()
        let q1Index = depths.count / 4
        let q3Index = (depths.count * 3) / 4
        let q1 = depths[q1Index]
        let q3 = depths[q3Index]
        let iqr = q3 - q1

        // IQR fence: standard 1.5x IQR outlier bounds
        let iqrLow = q1 - 1.5 * iqr
        let iqrHigh = q3 + 1.5 * iqr

        // Tap-based range: percentage tolerance without max clamp
        let tapTolerance = tapDepth * pipeline.depthFilterPercent
        let tapLow = tapDepth - tapTolerance
        let tapHigh = tapDepth + tapTolerance

        // Intersection of IQR fence and tap-based range
        var finalLow = max(iqrLow, tapLow)
        var finalHigh = min(iqrHigh, tapHigh)

        // Minimum guarantee: at least ±depthFilterMin around tap depth
        let minLow = tapDepth - pipeline.depthFilterMin
        let minHigh = tapDepth + pipeline.depthFilterMin
        finalLow = min(finalLow, minLow)
        finalHigh = max(finalHigh, minHigh)

#if DEBUG
        let median = depths[depths.count / 2]
        print("[DepthFilter] Adaptive: median=\(String(format: "%.3f", median))m, Q1=\(String(format: "%.3f", q1)), Q3=\(String(format: "%.3f", q3)), IQR=\(String(format: "%.3f", iqr))")
        print("[DepthFilter] Adaptive: IQR fence=[\(String(format: "%.3f", iqrLow)), \(String(format: "%.3f", iqrHigh))], tap range=[\(String(format: "%.3f", tapLow)), \(String(format: "%.3f", tapHigh))]")
        print("[DepthFilter] Adaptive: final range=[\(String(format: "%.3f", finalLow)), \(String(format: "%.3f", finalHigh))] (span=\(String(format: "%.3f", finalHigh - finalLow))m)")
#endif

        // Pass 2: Filter pixels using the adaptive range
        var filteredPixels: [(x: Int, y: Int)] = []
        filteredPixels.reserveCapacity(maskedPixels.count / 2)

        for pixel in maskedPixels {
            let depthX = Int(CGFloat(pixel.x) * scaleX)
            let depthY = Int(CGFloat(pixel.y) * scaleY)
            guard depthX >= 0 && depthX < depthWidth && depthY >= 0 && depthY < depthHeight else {
                continue
            }
            let pixelDepth = depthPtr[depthY * depthStride + depthX]
            if pixelDepth.isFinite && pixelDepth >= finalLow && pixelDepth <= finalHigh {
                filteredPixels.append(pixel)
            }
        }

#if DEBUG
        print("[DepthFilter] Adaptive: filtered \(maskedPixels.count) → \(filteredPixels.count) pixels")
#endif

        // Safety valve: proportional minimum, return empty on failure
        let minRequired = max(20, maskedPixels.count / 20)
        if filteredPixels.count < minRequired {
#if DEBUG
            print("[DepthFilter] Adaptive: too few pixels (\(filteredPixels.count) < \(minRequired)), returning empty")
#endif
            return []
        }

        return filteredPixels
    }

    /// Refine masked pixels by depth-based connected-component analysis.
    /// Keeps only the connected region around the seed pixel where depth is continuous.
    /// This separates objects that Vision grouped into a single instance but differ in depth.
    private func refineMaskedPixelsByDepthConnectivity(
        maskedPixels: [(x: Int, y: Int)],
        frame: ARFrame,
        seedPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard let depthMap = depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            return maskedPixels
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return maskedPixels
        }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)
        let depthStride = depthBytesPerRow / MemoryLayout<Float32>.size

        let scaleX = CGFloat(depthWidth) / imageSize.width
        let scaleY = CGFloat(depthHeight) / imageSize.height

        // Build spatial hash for fast neighbor lookup (cell size in image pixels)
        let cellSize = AppConstants.depthConnectivityCellSize
        struct Cell: Hashable { let x, y: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(maskedPixels.count / 4)
        for (i, px) in maskedPixels.enumerated() {
            let cell = Cell(x: px.x / cellSize, y: px.y / cellSize)
            grid[cell, default: []].append(i)
        }

        // Find seed: closest masked pixel to seedPoint (in image coordinates)
        let seedImgX = Int(seedPoint.x * imageSize.width)
        let seedImgY = Int(seedPoint.y * imageSize.height)
        var seedIdx = 0
        var minDist = Int.max
        for (i, px) in maskedPixels.enumerated() {
            let d = abs(px.x - seedImgX) + abs(px.y - seedImgY)
            if d < minDist { minDist = d; seedIdx = i }
        }

        // Get seed depth
        let seedPx = maskedPixels[seedIdx]
        let seedDX = Int(CGFloat(seedPx.x) * scaleX)
        let seedDY = Int(CGFloat(seedPx.y) * scaleY)
        guard seedDX >= 0 && seedDX < depthWidth && seedDY >= 0 && seedDY < depthHeight else {
            return maskedPixels
        }
        let seedDepth = depthPtr[seedDY * depthStride + seedDX]
        guard seedDepth.isFinite && seedDepth > 0 else { return maskedPixels }

        let seedTolerance = seedDepth * AppConstants.depthConnectivitySeedTolerance
        let localTolerance = AppConstants.depthConnectivityLocalTolerance

        // Helper: get depth for a masked pixel
        func depthAt(_ px: (x: Int, y: Int)) -> Float? {
            let dx = Int(CGFloat(px.x) * scaleX)
            let dy = Int(CGFloat(px.y) * scaleY)
            guard dx >= 0 && dx < depthWidth && dy >= 0 && dy < depthHeight else { return nil }
            let d = depthPtr[dy * depthStride + dx]
            return (d.isFinite && d > 0) ? d : nil
        }

        // Flood-fill through spatial hash neighbors
        var visited = [Bool](repeating: false, count: maskedPixels.count)
        var frontier: [Int] = [seedIdx]
        visited[seedIdx] = true
        var result: [Int] = [seedIdx]

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let px = maskedPixels[idx]
            guard let currentDepth = depthAt(px) else { continue }

            let cx = px.x / cellSize
            let cy = px.y / cellSize

            // Check 3x3 neighboring cells
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let neighbors = grid[Cell(x: cx + dx, y: cy + dy)] else { continue }
                    for ni in neighbors {
                        if visited[ni] { continue }
                        guard let neighborDepth = depthAt(maskedPixels[ni]) else { continue }

                        // (a) Within seed depth tolerance (global)
                        let seedDiff = abs(neighborDepth - seedDepth)
                        guard seedDiff <= seedTolerance else { continue }

                        // (b) Within local continuity tolerance
                        let localDiff = abs(neighborDepth - currentDepth)
                        guard localDiff <= currentDepth * localTolerance else { continue }

                        visited[ni] = true
                        frontier.append(ni)
                        result.append(ni)
                    }
                }
            }
        }

        let refined = result.map { maskedPixels[$0] }

#if DEBUG
        print("[DepthConnectivity] Seed depth: \(seedDepth)m, tolerance: ±\(seedTolerance)m")
        print("[DepthConnectivity] Refined from \(maskedPixels.count) to \(refined.count) pixels")
#endif

        // Safety: if too few pixels remain, skip refinement
        let minRetain = Int(Float(maskedPixels.count) * AppConstants.depthConnectivityMinRetainRatio)
        if refined.count < minRetain {
#if DEBUG
            print("[DepthConnectivity] Too few pixels retained (\(refined.count) < \(minRetain)), skipping refinement")
#endif
            return maskedPixels
        }

        return refined
    }

    /// Calculate volume from dimensions
    static func calculateVolume(length: Float, width: Float, height: Float) -> Float {
        length * width * height
    }

    /// Filter 3D points by proximity to a center point
    /// This uses world coordinates, bypassing problematic 2D coordinate conversions
    private func filterPointsByProximity(
        points: [SIMD3<Float>],
        center: SIMD3<Float>,
        maxDistance: Float
    ) -> [SIMD3<Float>] {
#if DEBUG
        print("[ProximityFilter] Filtering \(points.count) points around center: \(center)")
        print("[ProximityFilter] Max distance: \(maxDistance)m")
#endif

        var filteredPoints: [SIMD3<Float>] = []
        filteredPoints.reserveCapacity(points.count)
        var minDist: Float = .infinity, maxDist: Float = 0, totalDist: Float = 0

        for point in points {
            let d = simd_distance(point, center)
            minDist = min(minDist, d); maxDist = max(maxDist, d); totalDist += d
            if d <= maxDistance {
                filteredPoints.append(point)
            }
        }

        if !points.isEmpty {
#if DEBUG
            print("[ProximityFilter] Distance stats - min: \(minDist)m, max: \(maxDist)m, avg: \(totalDist / Float(points.count))m")
#endif
        }
#if DEBUG
        print("[ProximityFilter] Kept \(filteredPoints.count) of \(points.count) points")
#endif

        return filteredPoints
    }

    /// Extract the main cluster of points around the center using spatial-hash flood-fill
    /// This helps isolate the tapped object from other nearby objects
    private func extractMainCluster(points: [SIMD3<Float>], center: SIMD3<Float>, cameraPosition: SIMD3<Float>? = nil) -> [SIMD3<Float>] {
        let pipeline = AppConstants.currentPipelineVersion
        guard points.count > pipeline.clusteringGuardMinPoints else { return points }

#if DEBUG
        print("[Clustering] Starting with \(points.count) points")
#endif

        // Determine clustering threshold based on pipeline version
        let neighborThreshold: Float
        if let fixed = pipeline.clusteringFixedThreshold {
            neighborThreshold = fixed
        } else {
            // Adaptive (enhanced only)
            let medianDepth = estimateMedianDepth(points: points, cameraPosition: cameraPosition)
            let adaptive = AppConstants.clusteringBaseOffset + medianDepth * AppConstants.clusteringDepthScale
            neighborThreshold = min(max(adaptive, AppConstants.clusteringMinThreshold), AppConstants.clusteringMaxThreshold)
#if DEBUG
            print("[Clustering] Depth-adaptive threshold: \(neighborThreshold * 100)cm (medianDepth=\(medianDepth)m)")
#endif
        }
        let cellSize = neighborThreshold

        // Build spatial hash grid: cell → [point indices]
        struct Cell: Hashable { let x, y, z: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(points.count / 2)
        for (i, p) in points.enumerated() {
            let cell = Cell(x: Int(floor(p.x / cellSize)),
                            y: Int(floor(p.y / cellSize)),
                            z: Int(floor(p.z / cellSize)))
            grid[cell, default: []].append(i)
        }

        // Find seed (closest to center)
        var seedIdx = 0
        var minDist = simd_distance(points[0], center)
        for (i, p) in points.enumerated() {
            let d = simd_distance(p, center)
            if d < minDist { minDist = d; seedIdx = i }
        }
#if DEBUG
        print("[Clustering] Seed point at distance \(minDist)m from center")
#endif

        // Flood-fill using grid neighbors only (DFS with stack)
        var inCluster = [Bool](repeating: false, count: points.count)
        var frontier: [Int] = [seedIdx]
        inCluster[seedIdx] = true
        var clusterCount = 1

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let p = points[idx]
            let cx = Int(floor(p.x / cellSize))
            let cy = Int(floor(p.y / cellSize))
            let cz = Int(floor(p.z / cellSize))

            // Check only 27 neighboring cells
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let neighbors = grid[Cell(x: cx+dx, y: cy+dy, z: cz+dz)] else { continue }
                        for ni in neighbors {
                            if inCluster[ni] { continue }
                            if simd_distance(p, points[ni]) <= neighborThreshold {
                                inCluster[ni] = true
                                frontier.append(ni)
                                clusterCount += 1
                            }
                        }
                    }
                }
            }

            // Stop if cluster is getting too large (performance)
            if clusterCount > 10000 { break }
        }

        let clusterPoints = (0..<points.count).compactMap { inCluster[$0] ? points[$0] : nil }
#if DEBUG
        print("[Clustering] Extracted cluster with \(clusterPoints.count) points")
#endif

        // If cluster is too small, return original
        if clusterPoints.count < pipeline.clusteringGuardMinPoints {
#if DEBUG
            print("[Clustering] Cluster too small (\(clusterPoints.count) < \(pipeline.clusteringGuardMinPoints)), returning original points")
#endif
            return points
        }

        return clusterPoints
    }

    /// Estimate median depth (distance from camera) of point cloud
    private func estimateMedianDepth(points: [SIMD3<Float>], cameraPosition: SIMD3<Float>?) -> Float {
        guard !points.isEmpty else { return 1.0 }
        let origin = cameraPosition ?? .zero
        var distances = points.map { simd_distance($0, origin) }
        distances.sort()
        return distances[distances.count / 2]
    }

    /// Detect floor Y from horizontal ARPlaneAnchor below the object
    /// Filters to planes below the bounding box center and picks the lowest Y (actual floor)
    static func detectHorizontalPlaneFloorY(frame: ARFrame, nearPoint: SIMD3<Float>) -> Float? {
        let horizontalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
            guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .horizontal else { return nil }
            return plane
        }
        guard !horizontalPlanes.isEmpty else { return nil }

        // Filter to planes below the bounding box center (floor is below the object)
        // and within 3m XZ distance
        var candidatePlanes: [(plane: ARPlaneAnchor, y: Float, xzDist: Float)] = []
        for plane in horizontalPlanes {
            let planeY = plane.transform.columns.3.y
            // Only consider planes below the object center
            guard planeY < nearPoint.y else { continue }

            let xzDist = simd_distance(
                SIMD2<Float>(nearPoint.x, nearPoint.z),
                SIMD2<Float>(plane.transform.columns.3.x, plane.transform.columns.3.z)
            )
            guard xzDist < 3.0 else { continue }
            candidatePlanes.append((plane: plane, y: planeY, xzDist: xzDist))
        }

        // Pick the lowest Y plane (actual floor, not table)
        guard let best = candidatePlanes.min(by: { $0.y < $1.y }) else { return nil }
        let floorY = best.y
#if DEBUG
        print("[Calculator] Horizontal plane floor detected: y=\(floorY) (xzDist=\(best.xzDist)m, candidates=\(candidatePlanes.count))")
#endif
        return floorY
    }

    /// Extract the 2D connected component containing the seed point from the mask.
    /// Uses spatial-hash flood-fill (no depth checks) to separate non-touching objects
    /// that Vision may have merged into a single instance.
    private func extractConnectedComponent(
        maskedPixels: [(x: Int, y: Int)],
        seedPoint: CGPoint,
        imageSize: CGSize
    ) -> [(x: Int, y: Int)] {
        guard maskedPixels.count > 10 else { return maskedPixels }

        let cellSize = AppConstants.depthConnectivityCellSize
        struct Cell: Hashable { let x, y: Int }
        var grid: [Cell: [Int]] = [:]
        grid.reserveCapacity(maskedPixels.count / 4)
        for (i, px) in maskedPixels.enumerated() {
            let cell = Cell(x: px.x / cellSize, y: px.y / cellSize)
            grid[cell, default: []].append(i)
        }

        // Find seed: closest masked pixel to seedPoint (in image coordinates)
        let seedImgX = Int(seedPoint.x * imageSize.width)
        let seedImgY = Int(seedPoint.y * imageSize.height)
        var seedIdx = 0
        var minDist = Int.max
        for (i, px) in maskedPixels.enumerated() {
            let d = abs(px.x - seedImgX) + abs(px.y - seedImgY)
            if d < minDist { minDist = d; seedIdx = i }
        }

        // Flood-fill through spatial hash neighbors (pure 2D, no depth)
        var visited = [Bool](repeating: false, count: maskedPixels.count)
        var frontier: [Int] = [seedIdx]
        visited[seedIdx] = true
        var result: [Int] = [seedIdx]

        while !frontier.isEmpty {
            let idx = frontier.removeLast()
            let px = maskedPixels[idx]
            let cx = px.x / cellSize
            let cy = px.y / cellSize

            for dx in -1...1 {
                for dy in -1...1 {
                    guard let neighbors = grid[Cell(x: cx + dx, y: cy + dy)] else { continue }
                    for ni in neighbors {
                        if visited[ni] { continue }
                        visited[ni] = true
                        frontier.append(ni)
                        result.append(ni)
                    }
                }
            }
        }

        let connected = result.map { maskedPixels[$0] }

#if DEBUG
        print("[2DCC] Connected component: \(connected.count) of \(maskedPixels.count) pixels")
#endif

        // Safety: if less than 5% retained, skip (mask might be sparse)
        if connected.count < maskedPixels.count / 20 {
#if DEBUG
            print("[2DCC] Too few pixels retained (\(connected.count)), skipping 2D CC")
#endif
            return maskedPixels
        }

        return connected
    }

    /// Estimate the spatial spread (max extent) of a point cloud
    static func estimatePointSpread(points: [SIMD3<Float>]) -> Float {
        guard let first = points.first else { return 1.0 }
        var minP = first
        var maxP = first
        for p in points {
            minP = min(minP, p)
            maxP = max(maxP, p)
        }
        let extent = maxP - minP
        return max(extent.x, extent.y, extent.z)
    }
}
