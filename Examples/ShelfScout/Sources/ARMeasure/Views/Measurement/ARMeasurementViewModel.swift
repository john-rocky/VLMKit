//
//  ARMeasurementViewModel.swift
//  SnapMeasure
//

import SwiftUI
import RealityKit
import ARKit
import UIKit

// MARK: - View Model

@MainActor
class ARMeasurementViewModel: ObservableObject {
    @Published var trackingMessage = String(localized: "Initializing...")
    @Published var isTrackingReady = false
    @Published var isTrackingError = false
    @Published var isProcessing = false
    @Published var measurementError: String? = nil
    @Published var currentMeasurement: MeasurementCalculator.MeasurementResult?
    @Published var isEditing = false
    @Published var isDragging = false

    // Debug visualization
    #if DEBUG
    @Published var showDebugMask = false
    @Published var showDebugDepth = false
    @Published var debugMaskImage: UIImage?
    @Published var debugMaskImage2: UIImage?
    @Published var debugDepthImage: UIImage?
    var showMaskPreviewSetting = false

    // Pipeline diagnostics
    @Published var showDiagnosticsPanel = false
    @Published var lastPipelineDiagnostics: PipelineDiagnostics?
    var showDiagnosticsSetting = false

    // Stage point cloud visualization
    @Published var pointCloudCaptures: [PipelinePointCloudCapture] = []
    @Published var selectedVisualizationStage: PipelinePointCloudCapture.Stage?
    @Published var showPointCloudViz = false
    private var stageVisualizationAnchors: [AnchorEntity] = []
    #endif

    // Selected completed box for action icons
    @Published var selectedCompletedBoxId: Int? = nil

    // Refinement state
    @Published var isRefining = false
    private var refinementCount: Int = 0
    private var accumulatedPointClouds: [[SIMD3<Float>]] = []
    private var accumulatedQualities: [MeasurementQuality] = []
    private var originalAxisMapping: BoundingBox3D.AxisMapping?
    private var originalFloorY: Float?

    // Status vignette state
    @Published var showStatusVignette = false
    @Published var statusVignetteIsNG = false

    // Dimension callout state
    @Published var showDimensionCallout = false
    @Published var calloutLineRevealed: [Bool] = [false, false, false, false]
    @Published var calloutTransitionProgress: CGFloat = 0.0
    @Published var calloutTargetScreenPosition: CGPoint = .zero
    @Published var calloutBoxId: Int = 0
    @Published var calloutWidth: String = ""
    @Published var calloutHeight: String = ""
    @Published var calloutLength: String = ""

    // Two-tap flow: pending first-tap result (measured but not yet displayed)
    @Published var hasPendingFirstTap = false
    @Published var secondTapFailureMessage: String? = nil
    private var secondTapAttemptCount: Int = 0
    private var pendingFirstTapResult: MeasurementCalculator.MeasurementResult?
    private var pendingFirstTapFloorY: Float?
    private var pendingFirstTapFloorPlaneBacked = false

    // Enhanced pipeline: floor plane backing flag
    private var isFloorPlaneBacked = false

    /// Floor snap threshold: wider when backed by a detected horizontal plane
    private var floorSnapThreshold: Float {
        let pipeline = AppConstants.currentPipelineVersion
        return isFloorPlaneBacked
            ? pipeline.floorSnapWithPlane
            : pipeline.floorSnapDefault
    }

    // Reticle lock-on state
    @Published var reticleTargetState: ReticleTargetState = .noTarget
    @Published var reticleCenterDepth: Float = 0
    @Published var tapIndicatorPosition: CGPoint? = nil
    private var smoothedCenterDepth: Float = 0
    private var targetDetectedFrameCount: Int = 0
    private var cachedSegmentation: CachedSegmentation?
    private var backgroundSegmentationTask: Task<Void, Never>?
    private var lastBackgroundSegTime: TimeInterval = 0

    // Auto-detection: live preview measurement
    @Published private(set) var hasAutoPreview: Bool = false
    @Published private(set) var autoPreviewCaptureCount: Int = 0
    private var autoPreviewResult: MeasurementCalculator.MeasurementResult?
    private var autoPreviewTask: Task<Void, Never>?
    private var lastAutoPreviewTime: TimeInterval = 0
    // Accumulated points across multiple preview viewpoints
    private var accumulatedPreviewPoints: [SIMD3<Float>] = []
    private let autoPreviewMaxPoints = 30000
    private let autoPreviewMergeGridSize: Float = 0.005  // 5mm voxel

    private struct CachedSegmentation {
        let mask: CVPixelBuffer
        let maskSize: CGSize
        let instanceCount: Int
        let frameTimestamp: TimeInterval
        let cameraPosition: SIMD3<Float>
    }

    // Label reader state
    @Published var isReadingLabel = false
    @Published var showLabelResult = false
    @Published var showBarcodeScanEffect = false
    @Published var currentLabelData: LabelData?
    @Published var correctedLabelImageSize: CGSize = .zero
    @Published var correctedLabelImage: UIImage?
    @Published var labelLineRevealed: [Bool] = []
    @Published var labelReadingComplete = false

    // VLMKit description of the measured object. Set asynchronously after the
    // measurement finalizes (see `startObjectDescription`), shown in the
    // dimension callout alongside W/H/L. Cleared whenever the callout resets.
    @Published var objectDescription: String?
    @Published var isDescribingObject: Bool = false
    var pendingLabelData: LabelData?
    private let labelReaderService = LabelReaderService()
    private var labelLiftAnimation: LabelLiftAnimation?
    private var labelLiftAnchor: AnchorEntity?
    private var labelBillboard: LabelBillboard?
    private var labelBillboardAnchor: AnchorEntity?
    @Published var showLabelBillboard = false

    // Guided workflow state
    @Published var workflowStep: WorkflowStep = .idle


    var isWorkflowActive: Bool {
        workflowStep != .idle
    }

    // Current measurement mode (synced from view)
    var currentMeasurementMode: MeasurementMode = .boxPriority

    // Animation state - start with target brackets visible
    @Published var animationPhase: BoundingBoxAnimationPhase = .showingTargetBrackets
    @Published var animationContext: BoundingBoxAnimationContext?

    // Stability detection
    @Published var stabilityLevel: StabilityLevel = .moving
    private var stabilityWindowStart: Date?
    private var lastHapticLevel: StabilityLevel = .moving
    let animationCoordinator = BoxAnimationCoordinator()

    let sessionManager = ARSessionManager()
    private let measurementCalculator = MeasurementCalculator()
    private let boxEditingService = BoxEditingService()
    private var mlDepthEstimator: MLDepthEstimator?
    private var boxVisualization: BoxVisualization?
    private var boxVisualizationAnchor: AnchorEntity?
    private var pointCloudEntity: Entity?
    private var animatedBoxVisualization: AnimatedBoxVisualization?
    private var animatedBoxAnchor: AnchorEntity?

    // Stored point cloud for Fit functionality
    private var storedPointCloud: [SIMD3<Float>]?

    // Ghost box: translucent wireframe shown after first tap while awaiting second
    private var ghostBoxAnchor: AnchorEntity?
    private var ghostEdgeEntities: [ModelEntity] = []
    private var ghostCornerEntities: [ModelEntity] = []

    // Current measurement unit (passed from view)
    var currentUnit: MeasurementUnit = .centimeters

    // Box ID counter (increments with each save)
    private var nextBoxId: Int = 1

    // Completed (saved) box visualizations
    private var completedBoxVisualizations: [CompletedBoxVisualization] = []
    private var completedBoxAnchors: [AnchorEntity] = []
    private let maxCompletedBoxes = 10

    // Published count for UI
    @Published var completedBoxCount: Int = 0

    init() {
        sessionManager.$trackingStateMessage
            .assign(to: &$trackingMessage)
        sessionManager.$isTrackingReady
            .assign(to: &$isTrackingReady)
        sessionManager.$isTrackingError
            .assign(to: &$isTrackingError)

        // Setup frame update callback for billboard updates
        sessionManager.onFrameUpdate = { [weak self] frame in
            Task { @MainActor in
                self?.onFrameUpdate(frame: frame)
            }
        }
    }

    func startSession() {
        sessionManager.startSession()
        // Configure animation coordinator with AR view
        if let arView = sessionManager.arView {
            animationCoordinator.configure(arView: arView)
        }
        // Setup depth source based on device capabilities
        let depthSource = LiDARChecker.createDepthSource()
        measurementCalculator.depthSource = depthSource
        if let mlEstimator = depthSource as? MLDepthEstimator {
            mlDepthEstimator = mlEstimator
        }
    }

    /// Last camera position/forward for billboard delta check (skip updates when stationary)
    private var lastFrameCameraPosition: SIMD3<Float> = .zero
    private var lastFrameCameraForward: SIMD3<Float> = .init(0, 0, -1)

    /// Dedicated stability tracking (updated every frame, not gated by billboard guard)
    private var lastStabilityCameraPosition: SIMD3<Float> = .zero
    private var lastStabilityCameraForward: SIMD3<Float> = .init(0, 0, -1)
    private var smoothedPosDelta: Float = 0
    private var smoothedDirDelta: Float = 0
    private var violationCount: Int = 0

    /// Called on each AR frame update
    private func onFrameUpdate(frame: ARFrame) {
        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )
        let cameraForward = -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )

        // Stability detection (runs every frame with dedicated tracking, before billboard guard)
        let rawPosDelta = simd_distance(cameraPosition, lastStabilityCameraPosition)
        let rawDirDelta = simd_distance(cameraForward, lastStabilityCameraForward)
        lastStabilityCameraPosition = cameraPosition
        lastStabilityCameraForward = cameraForward
        updateStabilityLevel(rawPosDelta: rawPosDelta, rawDirDelta: rawDirDelta)

        // Reticle target detection (runs every frame in target-bracket phase)
        if animationPhase == .showingTargetBrackets && !isProcessing && !hasPendingFirstTap {
            updateReticleTarget(frame: frame, cameraPosition: cameraPosition)
        }

        // Skip billboard updates when camera is nearly stationary
        let billboardPosDelta = simd_distance(cameraPosition, lastFrameCameraPosition)
        let billboardDirDelta = simd_distance(cameraForward, lastFrameCameraForward)
        guard billboardPosDelta > 0.005 || billboardDirDelta > 0.01 else { return }
        lastFrameCameraPosition = cameraPosition
        lastFrameCameraForward = cameraForward

        // Active box billboard is always visible (excluded from prominence logic)
        // But hide during callout transition when 2D card is showing
        // Also hide permanently when unified label billboard is active
        if let boxViz = boxVisualization {
            let inCalloutPhase = animationPhase == .dimensionCallout || animationPhase == .calloutTransition
            let unifiedLabelActive = showLabelBillboard && (labelBillboard?.isUnified == true)
            if unifiedLabelActive {
                boxViz.setDimensionBillboardVisible(false)
            } else if !inCalloutPhase {
                boxViz.setDimensionBillboardVisible(true, forceShow: true)
            }
            boxViz.updateLabelOrientations(cameraPosition: cameraPosition)
        }

        // Label billboard orientation tracking
        if showLabelBillboard {
            labelBillboard?.updateOrientation(cameraPosition: cameraPosition)
        }

        // Find the most prominent completed box for billboard visibility
        let visibilityThreshold: Float = 0.3  // ~70° cone
        var maxDotProduct: Float = visibilityThreshold
        var mostProminentCompletedIndex: Int? = nil

        for (index, visualization) in completedBoxVisualizations.enumerated() {
            let toBox = visualization.boundingBox.center - cameraPosition
            let distance = simd_length(toBox)
            if distance > 0.01 {
                let dot = simd_dot(toBox / distance, cameraForward)
                if dot > maxDotProduct {
                    maxDotProduct = dot
                    mostProminentCompletedIndex = index
                }
            }
        }

        // Update billboard visibility and orientation for completed boxes
        for (index, visualization) in completedBoxVisualizations.enumerated() {
            let isProminent = (mostProminentCompletedIndex == index)
            visualization.setDimensionBillboardVisible(isProminent)
            if isProminent {
                visualization.updateLabelOrientations(cameraPosition: cameraPosition)
            }
        }
    }

    // MARK: - Stability Detection

    private func updateStabilityLevel(rawPosDelta: Float, rawDirDelta: Float) {
        // EMA smoothing to filter sensor noise
        let alpha = AppConstants.stabilityEMAAlpha
        smoothedPosDelta = alpha * rawPosDelta + (1.0 - alpha) * smoothedPosDelta
        smoothedDirDelta = alpha * rawDirDelta + (1.0 - alpha) * smoothedDirDelta

        let isStill = smoothedPosDelta < AppConstants.stabilityPositionThreshold
            && smoothedDirDelta < AppConstants.stabilityRotationThreshold

        if !isStill {
            // Hysteresis: allow a few violation frames before demoting
            violationCount += 1
            if violationCount >= AppConstants.stabilityViolationTolerance {
                // Gradual demotion: drop one level at a time
                let demoted: StabilityLevel
                switch stabilityLevel {
                case .locked:   demoted = .stable
                case .stable:   demoted = .settling
                case .settling: demoted = .moving
                case .moving:   demoted = .moving
                }
                if demoted != stabilityLevel {
                    stabilityLevel = demoted
                    lastHapticLevel = demoted
                    // Reset window to allow re-progression from new level
                    if demoted == .moving {
                        stabilityWindowStart = nil
                    }
                }
                violationCount = 0
            }
            return
        }

        // Device is still — reset violation counter, start or continue timing
        violationCount = 0
        let now = Date()
        if stabilityWindowStart == nil {
            stabilityWindowStart = now
        }
        let elapsed = now.timeIntervalSince(stabilityWindowStart!)

        let newLevel: StabilityLevel
        if elapsed >= AppConstants.stabilityLockedTime {
            newLevel = .locked
        } else if elapsed >= AppConstants.stabilityStableTime {
            newLevel = .stable
        } else if elapsed >= AppConstants.stabilitySettlingTime {
            newLevel = .settling
        } else {
            newLevel = .moving
        }

        if newLevel != stabilityLevel {
            stabilityLevel = newLevel
            lastHapticLevel = newLevel
        }
    }

    private func triggerStabilityHaptic() {
        // Disabled — felt too noisy when reticle locked frequently
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.6)
    }

    // MARK: - Reticle Target Detection

    private func updateReticleTarget(frame: ARFrame, cameraPosition: SIMD3<Float>) {
        guard let depthMap = measurementCalculator.depthSource?.depthMap(for: frame) ?? frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap else {
            transitionReticleState(to: .noTarget)
            return
        }

        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Screen center → depth map coordinates
        // Screen center is (viewWidth/2, viewHeight/2).
        // In the landscape depth map: depthX = screenY / screenH * depthW, depthY = (1 - screenX / screenW) * depthH
        // For screen center: depthX = 0.5 * depthWidth, depthY = 0.5 * depthHeight
        let centerDX = depthWidth / 2
        let centerDY = depthHeight / 2

        // Sample center depth
        guard let centerDepthValue = sampleDepthAt(x: centerDX, y: centerDY, depthMap: depthMap) else {
            transitionReticleState(to: .noTarget)
            return
        }

        // Sample 8 surrounding points (cross pattern, ±15px offset in depth map space)
        let offset = 15
        let offsets = [
            (offset, 0), (-offset, 0), (0, offset), (0, -offset),
            (offset, offset), (-offset, -offset), (offset, -offset), (-offset, offset)
        ]
        var surroundingDepths: [Float] = []
        for (dx, dy) in offsets {
            if let d = sampleDepthAt(x: centerDX + dx, y: centerDY + dy, depthMap: depthMap) {
                surroundingDepths.append(d)
            }
        }

        // Check for depth discontinuity (edge detection)
        var hasDiscontinuity = false
        for d in surroundingDepths {
            if abs(d - centerDepthValue) > AppConstants.reticleDepthDiscontinuity {
                hasDiscontinuity = true
                break
            }
        }

        // EMA smoothing
        let alpha = AppConstants.reticleDepthEMAAlpha
        smoothedCenterDepth = alpha * centerDepthValue + (1.0 - alpha) * smoothedCenterDepth

        // Determine new state
        let newState: ReticleTargetState
        if smoothedCenterDepth >= AppConstants.reticleMinDepth
            && smoothedCenterDepth <= AppConstants.reticleMaxDepth
            && !hasDiscontinuity {
            if stabilityLevel >= .stable {
                newState = .targetLocked
            } else {
                newState = .targetDetected
            }
        } else if smoothedCenterDepth >= AppConstants.reticleMinDepth
                    && smoothedCenterDepth <= AppConstants.reticleMaxDepth {
            // Object detected but on an edge — still detected, not locked
            newState = .targetDetected
        } else {
            newState = .noTarget
        }

        transitionReticleState(to: newState)

        // Update published depth for UI
        if reticleTargetState != .noTarget {
            reticleCenterDepth = smoothedCenterDepth
        }

        // Background segmentation management
        // Allow auto-preview during motion (.targetDetected) so the user can scan
        // around the object continuously, like Apple's Object Capture.
        if reticleTargetState == .targetLocked {
            startBackgroundSegmentationIfNeeded(frame: frame, cameraPosition: cameraPosition)
            startAutoPreviewIfNeeded(frame: frame)
        } else if reticleTargetState == .targetDetected {
            startAutoPreviewIfNeeded(frame: frame)
        } else if reticleTargetState == .noTarget {
            stopBackgroundSegmentation()
            // Keep accumulated preview data during momentary reticle drops
            // so the instruction card doesn't flicker between holdSteady/scanAround
            if autoPreviewCaptureCount == 0 {
                clearAutoPreview()
            } else {
                autoPreviewTask?.cancel()
                autoPreviewTask = nil
            }
        }
    }

    private func sampleDepthAt(x: Int, y: Int, depthMap: CVPixelBuffer) -> Float? {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard x >= 0, x < width, y >= 0, y < height else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr = base.assumingMemoryBound(to: Float32.self)
        let stride = bytesPerRow / MemoryLayout<Float32>.size

        let depth = ptr[y * stride + x]
        return (depth.isFinite && depth > 0) ? depth : nil
    }

    private func transitionReticleState(to newState: ReticleTargetState) {
        if newState.rawValue > reticleTargetState.rawValue {
            // Promote: require threshold frames
            targetDetectedFrameCount += 1
            if targetDetectedFrameCount >= AppConstants.reticleTargetFrameThreshold {
                reticleTargetState = newState
                targetDetectedFrameCount = 0
            }
        } else if newState.rawValue < reticleTargetState.rawValue {
            // Demote immediately
            reticleTargetState = newState
            targetDetectedFrameCount = 0
        }
        // Equal: no change needed
    }

    private func startBackgroundSegmentationIfNeeded(frame: ARFrame, cameraPosition: SIMD3<Float>) {
        let now = frame.timestamp
        guard now - lastBackgroundSegTime >= AppConstants.reticleBackgroundSegInterval else { return }
        guard backgroundSegmentationTask == nil else { return }

        lastBackgroundSegTime = now
        let capturedImage = frame.capturedImage
        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(capturedImage),
            height: CVPixelBufferGetHeight(capturedImage)
        )

        // Screen center in normalized image coordinates
        // Screen center (0.5, 0.5) → normalizedX = 0.5, normalizedY = 1 - 0.5 = 0.5
        let normalizedCenter = CGPoint(x: 0.5, y: 0.5)

        backgroundSegmentationTask = Task { [weak self] in
            do {
                let segResult = try await InstanceSegmentationService().segmentInstance(
                    in: capturedImage,
                    at: normalizedCenter,
                    depthMap: depthMap
                )
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if let seg = segResult {
                        self.cachedSegmentation = CachedSegmentation(
                            mask: seg.mask,
                            maskSize: seg.maskSize,
                            instanceCount: {
                                #if DEBUG
                                return seg.instanceCount
                                #else
                                return 0
                                #endif
                            }(),
                            frameTimestamp: now,
                            cameraPosition: cameraPosition
                        )
                    }
                    self.backgroundSegmentationTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.backgroundSegmentationTask = nil
                }
            }
        }
    }

    private func stopBackgroundSegmentation() {
        backgroundSegmentationTask?.cancel()
        backgroundSegmentationTask = nil
        cachedSegmentation = nil
    }

    // MARK: - Auto Preview Measurement

    private func startAutoPreviewIfNeeded(frame: ARFrame) {
        // Skip if already processing or pending first-tap state
        guard !isProcessing && !hasPendingFirstTap else { return }
        // Skip during editing/refining/label scanning
        guard !isEditing && !isRefining && !isReadingLabel else { return }
        // Throttle: at most once per 1.5s
        let now = frame.timestamp
        guard now - lastAutoPreviewTime >= 1.5 else { return }
        guard autoPreviewTask == nil else { return }

        let viewSize = sessionManager.arView.bounds.size
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let mode = currentMeasurementMode

        lastAutoPreviewTime = now
        let verticalPlanes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .vertical }

        autoPreviewTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await self.measurementCalculator.measure(
                    frame: frame,
                    tapPoint: center,
                    viewSize: viewSize,
                    mode: mode
                )
                guard !Task.isCancelled else { return }
                guard !self.isProcessing && !self.hasPendingFirstTap else {
                    self.autoPreviewTask = nil
                    return
                }
                guard let r = result, let newPoints = r.pointCloud, !newPoints.isEmpty else {
                    self.autoPreviewTask = nil
                    return
                }

                let newCentroid = Self.centroid(newPoints)

                // If a measurement is currently active, only show preview when pointing
                // at a clearly different object. Otherwise the preview overlaps the
                // active wireframe and creates visual noise.
                if let active = self.currentMeasurement {
                    let activeCenter = active.boundingBox.center
                    let activeSpan = max(active.boundingBox.extents.x, max(active.boundingBox.extents.y, active.boundingBox.extents.z))
                    let separation = simd_distance(activeCenter, newCentroid)
                    // Require new centroid to be outside the active box (with margin)
                    let minSeparation = activeSpan * 0.7 + 0.05
                    if separation < minSeparation {
                        self.autoPreviewTask = nil
                        return
                    }
                }

                // Object continuity check: compare new centroid against accumulated centroid.
                // If too far apart, the user has moved to a different object — reset accumulation.
                let sameObject: Bool = {
                    guard !self.accumulatedPreviewPoints.isEmpty else { return true }
                    let prevCentroid = Self.centroid(self.accumulatedPreviewPoints)
                    let distance = simd_distance(prevCentroid, newCentroid)
                    // Allow drift up to half the diagonal of the existing box, capped at 25cm
                    let span = Self.maxSpan(self.accumulatedPreviewPoints)
                    let threshold = max(0.05, min(0.25, span * 0.5))
                    return distance < threshold
                }()

                if !sameObject {
                    self.accumulatedPreviewPoints.removeAll(keepingCapacity: true)
                    self.autoPreviewCaptureCount = 0
                }

                // Accumulate point cloud across viewpoints
                self.accumulatedPreviewPoints.append(contentsOf: newPoints)
                self.accumulatedPreviewPoints = Self.downsampleByVoxel(
                    self.accumulatedPreviewPoints,
                    gridSize: self.autoPreviewMergeGridSize
                )
                // FIFO cap: keep most recent points if over limit
                if self.accumulatedPreviewPoints.count > self.autoPreviewMaxPoints {
                    let drop = self.accumulatedPreviewPoints.count - self.autoPreviewMaxPoints
                    self.accumulatedPreviewPoints.removeFirst(drop)
                }

                // Re-estimate bounding box from accumulated points
                guard let mergedBox = BoundingBoxEstimator().estimateBoundingBox(
                    points: self.accumulatedPreviewPoints,
                    mode: mode,
                    verticalPlaneAnchors: verticalPlanes
                ) else {
                    self.autoPreviewTask = nil
                    return
                }

                // Recalculate with merged box, preserving latest result's axis mapping
                var mergedResult = self.measurementCalculator.recalculate(
                    boundingBox: mergedBox,
                    quality: r.quality,
                    axisMapping: r.axisMapping
                )
                mergedResult.pointCloud = self.accumulatedPreviewPoints
                mergedResult.detectedFloorY = r.detectedFloorY

                self.autoPreviewResult = mergedResult
                self.hasAutoPreview = true
                self.autoPreviewCaptureCount += 1
                self.showGhostBox(for: mergedBox)
                self.autoPreviewTask = nil
            } catch {
                self.autoPreviewTask = nil
            }
        }
    }

    private func clearAutoPreview() {
        autoPreviewTask?.cancel()
        autoPreviewTask = nil
        autoPreviewResult = nil
        hasAutoPreview = false
        autoPreviewCaptureCount = 0
        accumulatedPreviewPoints.removeAll(keepingCapacity: false)
        // Only remove ghost if no pending first-tap result
        if !hasPendingFirstTap {
            removeGhostBox()
        }
    }

    static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var sum = SIMD3<Float>.zero
        for p in points { sum += p }
        return sum / Float(points.count)
    }

    static func maxSpan(_ points: [SIMD3<Float>]) -> Float {
        guard let first = points.first else { return 0 }
        var minP = first, maxP = first
        for p in points {
            minP = min(minP, p)
            maxP = max(maxP, p)
        }
        let extents = maxP - minP
        return max(extents.x, max(extents.y, extents.z))
    }

    /// Voxel-grid downsampling: 1 representative point per cell
    static func downsampleByVoxel(_ points: [SIMD3<Float>], gridSize: Float) -> [SIMD3<Float>] {
        guard gridSize > 0, !points.isEmpty else { return points }
        let inv = 1.0 / gridSize
        var seen: [SIMD3<Int32>: SIMD3<Float>] = [:]
        seen.reserveCapacity(points.count)
        for p in points {
            let key = SIMD3<Int32>(
                Int32((p.x * inv).rounded()),
                Int32((p.y * inv).rounded()),
                Int32((p.z * inv).rounded())
            )
            if seen[key] == nil { seen[key] = p }
        }
        return Array(seen.values)
    }

    /// Promote auto-preview to active measurement (skip re-measuring)
    private func confirmAutoPreview(_ result: MeasurementCalculator.MeasurementResult, mode: MeasurementMode) {
        guard let frame = sessionManager.currentFrame else { return }
        let viewSize = sessionManager.arView.bounds.size
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let floorY = result.detectedFloorY
        isFloorPlaneBacked = result.detectedFloorY != nil
        originalFloorY = floorY

        // Auto-save existing measurement as completed (so the new one can take over)
        if let existing = currentMeasurement {
            convertActiveBoxToCompleted(result: existing, unit: currentUnit)
            currentMeasurement = nil
            animationCoordinator.cancelAnimation()
            animationContext = nil
        }

        // Clean up auto-preview state but keep ghost momentarily (animation will replace)
        autoPreviewTask?.cancel()
        autoPreviewTask = nil
        autoPreviewResult = nil
        hasAutoPreview = false
        autoPreviewCaptureCount = 0
        accumulatedPreviewPoints.removeAll(keepingCapacity: false)
        removeGhostBox()

        // Reset pending state
        pendingFirstTapResult = nil
        pendingFirstTapFloorY = nil
        pendingFirstTapFloorPlaneBacked = false
        hasPendingFirstTap = false

        // Show animated wireframe with the auto-preview result
        startBoxAnimation(
            at: center,
            boundingBox: result.boundingBox,
            frame: frame,
            viewSize: viewSize,
            result: result,
            floorY: floorY
        )
    }

    private func clearReticleState() {
        reticleTargetState = .noTarget
        reticleCenterDepth = 0
        smoothedCenterDepth = 0
        targetDetectedFrameCount = 0
        stopBackgroundSegmentation()
        clearAutoPreview()
    }

    func pauseSession() {
        sessionManager.pauseSession()
    }

    func handleTap(at location: CGPoint, mode: MeasurementMode) async {
        #if DEBUG
        print("[ViewModel] handleTap called at \(location)")
        print("[ViewModel] isProcessing: \(isProcessing), trackingState: \(sessionManager.trackingState)")
        #endif

        // Show tap indicator
        showTapIndicator(at: location)

        // Auto-preview confirmation: if a ghost preview exists, promote it directly
        if let preview = autoPreviewResult, !isProcessing && currentMeasurement == nil && !hasPendingFirstTap {
            #if DEBUG
            print("[ViewModel] Confirming auto-preview as active measurement")
            #endif
            confirmAutoPreview(preview, mode: mode)
            return
        }

        guard !isProcessing else {
            #if DEBUG
            print("[ViewModel] Already processing, ignoring tap")
            #endif
            return
        }

        guard let frame = sessionManager.currentFrame else {
            #if DEBUG
            print("[ViewModel] No current frame available")
            #endif
            return
        }

        // Allow tapping even with limited tracking for testing
        guard sessionManager.trackingState == .normal ||
              (sessionManager.trackingState != .notAvailable) else {
            #if DEBUG
            print("[ViewModel] Tracking state not ready: \(sessionManager.trackingState)")
            #endif
            return
        }

        // Reset stability and reticle state on tap
        stabilityLevel = .moving
        stabilityWindowStart = nil
        lastHapticLevel = .moving
        smoothedPosDelta = 0
        smoothedDirDelta = 0
        violationCount = 0
        reticleTargetState = .noTarget
        reticleCenterDepth = 0

        // Two-tap flow: if we have a pending first-tap result, this is the second tap
        if let firstResult = pendingFirstTapResult {
            await handleSecondTap(at: location, mode: mode, firstResult: firstResult, frame: frame)
            return
        }

        // Auto-save current measurement as completed box before starting new one
        if let existingResult = currentMeasurement {
            #if DEBUG
            print("[ViewModel] Auto-saving existing measurement before new tap")
            #endif
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)

            // Transfer label billboard to the newly completed viz
            if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
               let lastViz = completedBoxVisualizations.last {
                lastViz.attachLabelBillboard(billboard, anchor: anchor)
                labelBillboard = nil
                labelBillboardAnchor = nil
                showLabelBillboard = false
            }
        }

        // Clean up previous measurement to free memory
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        #if DEBUG
        debugMaskImage = nil
        debugMaskImage2 = nil
        debugDepthImage = nil
        #endif
        animationContext = nil

        isProcessing = true

        // Stop background segmentation (we'll use cache if valid)
        backgroundSegmentationTask?.cancel()
        backgroundSegmentationTask = nil

        #if DEBUG
        print("[ViewModel] Starting first-tap measurement (silent)...")
        #endif

        // Get 3D world position from raycast
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)
        #if DEBUG
        if let pos = raycastHitPosition {
            print("[ViewModel] Raycast hit position: \(pos)")
        } else {
            print("[ViewModel] Raycast did not hit any surface")
        }
        #endif

        // Calibrate ML depth estimator using raycast distance
        if let mlEstimator = mlDepthEstimator, let hitPos = raycastHitPosition,
           let frame = sessionManager.currentFrame {
            let cameraPos = frame.camera.transform.columns.3
            let distance = simd_length(SIMD3<Float>(hitPos.x - cameraPos.x, hitPos.y - cameraPos.y, hitPos.z - cameraPos.z))
            let viewSize = sessionManager.arView.bounds.size
            let normalizedPoint = CGPoint(x: location.x / viewSize.width, y: location.y / viewSize.height)
            mlEstimator.calibrate(raycastDistance: distance, normalizedPoint: normalizedPoint, frame: frame)
        }

        do {
            let viewSize = sessionManager.arView.bounds.size
            #if DEBUG
            print("[ViewModel] View size: \(viewSize)")
            #endif

            // Check if cached segmentation can be used (tap near center + fresh cache)
            let result: MeasurementCalculator.MeasurementResult?
            let screenCenter = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            let tapDistance = hypot(location.x - screenCenter.x, location.y - screenCenter.y)
            let screenDiagonal = hypot(viewSize.width, viewSize.height)
            let cameraPos = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )

            if tapDistance / screenDiagonal < AppConstants.reticleTapCenterThreshold,
               let cached = cachedSegmentation,
               frame.timestamp - cached.frameTimestamp < AppConstants.reticleCacheFreshnessTime,
               simd_distance(cameraPos, cached.cameraPosition) < AppConstants.reticleCacheMaxMovement {
                #if DEBUG
                print("[ViewModel] Using cached segmentation (age: \(String(format: "%.0f", (frame.timestamp - cached.frameTimestamp) * 1000))ms)")
                #endif
                result = try await measurementCalculator.measureWithCachedSegmentation(
                    frame: frame,
                    cachedMask: cached.mask,
                    cachedMaskSize: cached.maskSize,
                    tapPoint: location,
                    viewSize: viewSize,
                    mode: mode,
                    raycastHitPosition: raycastHitPosition
                )
            } else {
                result = try await measurementCalculator.measure(
                    frame: frame,
                    tapPoint: location,
                    viewSize: viewSize,
                    mode: mode,
                    raycastHitPosition: raycastHitPosition
                )
            }

            // Clear cache after use
            cachedSegmentation = nil

            if let result = result {
                #if DEBUG
                print("[ViewModel] First-tap measurement successful (silent)")
                print("[ViewModel] Dimensions: L=\(result.length*100)cm, W=\(result.width*100)cm, H=\(result.height*100)cm")
                captureDiagnostics()
                #endif

                // Store as pending first-tap result
                pendingFirstTapResult = result
                pendingFirstTapFloorY = result.detectedFloorY ?? raycastHitPosition?.y
                pendingFirstTapFloorPlaneBacked = result.detectedFloorY != nil
                hasPendingFirstTap = true

                // Show ghost wireframe of first-tap measurement
                showGhostBox(for: result.boundingBox)

                // Start guided workflow
                workflowStep = .awaitingSecondTap
                #if DEBUG
                print("[Workflow] First tap complete, workflowStep=\(workflowStep)")
                #endif

                // Seed refinement accumulators for the merge on second tap
                if let pc = result.pointCloud {
                    accumulatedPointClouds = [pc]
                } else {
                    accumulatedPointClouds = []
                }
                accumulatedQualities = [result.quality]
                originalAxisMapping = result.axisMapping
                secondTapAttemptCount = 0
                secondTapFailureMessage = nil

                isProcessing = false
            } else {
                #if DEBUG
                print("[ViewModel] First-tap measurement returned nil")
                captureDiagnostics()
                #endif
                isProcessing = false
                showTemporaryError(guidedErrorMessage())
            }
        } catch {
            #if DEBUG
            print("[ViewModel] First-tap measurement failed with error: \(error)")
            captureDiagnostics()
            #endif
            isProcessing = false
            showTemporaryError(guidedErrorMessage())
        }
    }

    /// Second tap: refine with the pending first-tap result, then show animated box
    private func handleSecondTap(at location: CGPoint, mode: MeasurementMode, firstResult: MeasurementCalculator.MeasurementResult, frame: ARFrame) async {
        isProcessing = true
        #if DEBUG
        print("[ViewModel] Starting second-tap refinement...")
        #endif

        let viewSize = sessionManager.arView.bounds.size
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)

        do {
            if let refinement = try await measurementCalculator.measureForRefinement(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize,
                mode: mode,
                existingBox: firstResult.boundingBox,
                raycastHitPosition: raycastHitPosition
            ) {
                // Merge point clouds from both taps
                accumulatedPointClouds.append(refinement.points)
                accumulatedQualities.append(refinement.quality)
                refinementCount = 1

                let mergedPoints = accumulatedPointClouds.flatMap { $0 }
                let mergedQuality = MeasurementQuality.merged(accumulatedQualities)

                // Re-estimate bounding box from merged points
                let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                    guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                    return plane
                }

                guard let newBox = BoundingBoxEstimator().estimateBoundingBox(
                    points: mergedPoints, mode: mode, verticalPlaneAnchors: verticalPlanes
                ) else {
                    #if DEBUG
                    print("[ViewModel] Second-tap re-estimation failed, retrying or falling back")
                    #endif
                    handleSecondTapFailure(at: location, firstResult: firstResult, frame: frame)
                    return
                }

                // Apply floor extension
                var adjustedBox = newBox
                let floorY = pendingFirstTapFloorY ?? raycastHitPosition?.y
                isFloorPlaneBacked = pendingFirstTapFloorPlaneBacked
                if let floorY = floorY {
                    adjustedBox.extendBottomToFloor(floorY: floorY, threshold: floorSnapThreshold)
                }

                // Recalculate with original axis mapping
                let mapping = originalAxisMapping ?? firstResult.axisMapping
                var mergedResult = measurementCalculator.recalculate(
                    boundingBox: adjustedBox, quality: mergedQuality, axisMapping: mapping
                )
                mergedResult.pointCloud = mergedPoints
                #if DEBUG
                mergedResult.debugMaskImage = firstResult.debugMaskImage
                mergedResult.debugDepthImage = firstResult.debugDepthImage

                // Store debug images (both taps)
                debugMaskImage = firstResult.debugMaskImage
                debugMaskImage2 = refinement.debugMaskImage
                debugDepthImage = firstResult.debugDepthImage
                if showMaskPreviewSetting {
                    showDebugMask = true
                }
                #endif

                // Clear pending state
                pendingFirstTapResult = nil
                removeGhostBox()
                pendingFirstTapFloorY = nil
                pendingFirstTapFloorPlaneBacked = false
                hasPendingFirstTap = false
                originalFloorY = floorY

                #if DEBUG
                print("[ViewModel] Second-tap refinement successful! Dimensions: L=\(mergedResult.length*100)cm W=\(mergedResult.width*100)cm H=\(mergedResult.height*100)cm")
                captureDiagnostics()
                #endif

                // Now show the animation with the refined result
                startBoxAnimation(
                    at: location,
                    boundingBox: adjustedBox,
                    frame: frame,
                    viewSize: viewSize,
                    result: mergedResult,
                    floorY: floorY
                )
            } else {
                #if DEBUG
                print("[ViewModel] Second-tap refinement: object not matched, retrying or falling back")
                #endif
                handleSecondTapFailure(at: location, firstResult: firstResult, frame: frame)
            }
        } catch {
            #if DEBUG
            print("[ViewModel] Second-tap refinement error: \(error), retrying or falling back")
            #endif
            handleSecondTapFailure(at: location, firstResult: firstResult, frame: frame)
        }
    }

    /// Fallback: show first-tap result with animation when second tap refinement fails
    private func showFirstTapResultWithAnimation(at location: CGPoint, firstResult: MeasurementCalculator.MeasurementResult, frame: ARFrame) {
        let viewSize = sessionManager.arView.bounds.size
        let floorY = pendingFirstTapFloorY
        isFloorPlaneBacked = pendingFirstTapFloorPlaneBacked

        // Store debug images
        #if DEBUG
        debugMaskImage = firstResult.debugMaskImage
        debugMaskImage2 = nil
        debugDepthImage = firstResult.debugDepthImage
        if showMaskPreviewSetting {
            showDebugMask = true
        }
        #endif

        // Clear pending state
        pendingFirstTapResult = nil
        pendingFirstTapFloorY = nil
        pendingFirstTapFloorPlaneBacked = false
        hasPendingFirstTap = false
        originalFloorY = floorY

        // Show animation with first-tap result
        startBoxAnimation(
            at: location,
            boundingBox: firstResult.boundingBox,
            frame: frame,
            viewSize: viewSize,
            result: firstResult,
            floorY: floorY
        )
    }

    /// Handle second-tap failure: retry up to maxSecondTapAttempts, then fall back to first-tap result
    private func handleSecondTapFailure(at location: CGPoint, firstResult: MeasurementCalculator.MeasurementResult, frame: ARFrame) {
        secondTapAttemptCount += 1
        if secondTapAttemptCount >= AppConstants.maxSecondTapAttempts {
            // Max retries exceeded — fall back to first-tap result
            secondTapFailureMessage = nil
            secondTapAttemptCount = 0
            showFirstTapResultWithAnimation(at: location, firstResult: firstResult, frame: frame)
            return
        }
        // Retry allowed: keep pending state, show feedback
        isProcessing = false
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        let remaining = AppConstants.maxSecondTapAttempts - secondTapAttemptCount
        secondTapFailureMessage = String(localized: "Refinement failed — tap again (\(remaining) left)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.secondTapFailureMessage != nil {
                self.secondTapFailureMessage = nil
            }
        }
    }

    /// Skip second-tap refinement and use first-tap result immediately
    func skipSecondTap() {
        guard let firstResult = pendingFirstTapResult,
              let frame = sessionManager.currentFrame else { return }
        secondTapFailureMessage = nil
        secondTapAttemptCount = 0
        let center = CGPoint(x: sessionManager.arView.bounds.midX, y: sessionManager.arView.bounds.midY)
        showFirstTapResultWithAnimation(at: center, firstResult: firstResult, frame: frame)
    }

    func handleBoxSelection(rect: CGRect, viewSize: CGSize, mode: MeasurementMode) async {
        #if DEBUG
        print("[ViewModel] handleBoxSelection called with rect: \(rect)")
        print("[ViewModel] isProcessing: \(isProcessing), trackingState: \(sessionManager.trackingState)")
        #endif

        guard !isProcessing else {
            #if DEBUG
            print("[ViewModel] Already processing, ignoring box selection")
            #endif
            return
        }

        guard let frame = sessionManager.currentFrame else {
            #if DEBUG
            print("[ViewModel] No current frame available")
            #endif
            return
        }

        guard sessionManager.trackingState == .normal ||
              (sessionManager.trackingState != .notAvailable) else {
            #if DEBUG
            print("[ViewModel] Tracking state not ready: \(sessionManager.trackingState)")
            #endif
            return
        }

        // Auto-save current measurement as completed box before starting new one
        if let existingResult = currentMeasurement {
            #if DEBUG
            print("[ViewModel] Auto-saving existing measurement before new box selection")
            #endif
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)
        }

        // Clean up previous measurement and pending first-tap state
        removeAllVisualizations()
        animationCoordinator.cancelAnimation()
        currentMeasurement = nil
        #if DEBUG
        debugMaskImage = nil
        debugMaskImage2 = nil
        debugDepthImage = nil
        #endif
        animationContext = nil
        clearPendingFirstTap()

        isProcessing = true
        #if DEBUG
        print("[ViewModel] Starting box selection measurement...")
        #endif

        // Raycast from box center
        let boxCenter = CGPoint(x: rect.midX, y: rect.midY)
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: boxCenter)
        #if DEBUG
        if let pos = raycastHitPosition {
            print("[ViewModel] Raycast hit position from box center: \(pos)")
        } else {
            print("[ViewModel] Raycast did not hit any surface from box center")
        }
        #endif

        do {
            if let result = try await measurementCalculator.measureWithROI(
                frame: frame,
                regionOfInterest: rect,
                viewSize: viewSize,
                mode: mode,
                raycastHitPosition: raycastHitPosition
            ) {
                #if DEBUG
                print("[ViewModel] Box selection measurement successful!")
                print("[ViewModel] Dimensions: L=\(result.length*100)cm, W=\(result.width*100)cm, H=\(result.height*100)cm")
                captureDiagnostics()
                #endif

                #if DEBUG
                debugMaskImage = result.debugMaskImage
                debugMaskImage2 = nil
                debugDepthImage = result.debugDepthImage
                if showMaskPreviewSetting {
                    showDebugMask = true
                }
                #endif

                let floorY = result.detectedFloorY ?? raycastHitPosition?.y
                isFloorPlaneBacked = result.detectedFloorY != nil

                startBoxAnimation(
                    at: boxCenter,
                    boundingBox: result.boundingBox,
                    frame: frame,
                    viewSize: viewSize,
                    result: result,
                    floorY: floorY
                )
            } else {
                #if DEBUG
                print("[ViewModel] Box selection measurement returned nil")
                captureDiagnostics()
                #endif
                isProcessing = false
                showTemporaryError(String(localized: "Measurement failed. Try again."))
            }
        } catch {
            #if DEBUG
            print("[ViewModel] Box selection measurement failed with error: \(error)")
            captureDiagnostics()
            #endif
            isProcessing = false
            showTemporaryError(String(localized: "Measurement failed. Try again."))
        }
    }

    /// Start the bounding box appearance animation
    private func startBoxAnimation(
        at tapPoint: CGPoint,
        boundingBox: BoundingBox3D,
        frame: ARFrame,
        viewSize: CGSize,
        result: MeasurementCalculator.MeasurementResult,
        floorY: Float?
    ) {
        // Get camera transform for starting position
        let cameraTransform = frame.camera.transform

        // Phase 1: Edge trace - draw bottom edges sequentially
        animationPhase = .edgeTrace

        // Create animated box visualization
        animatedBoxVisualization = AnimatedBoxVisualization(boundingBox: boundingBox)
        guard let animatedBox = animatedBoxVisualization else {
            isProcessing = false
            return
        }

        // Setup the 3D rect at camera position
        animatedBox.setupAtCameraPosition(
            cameraTransform: cameraTransform,
            distanceFromCamera: 0.5,
            rectSize: 0.25
        )
        animatedBoxAnchor = sessionManager.addEntityWithAnchor(animatedBox.entity)

        // Phase 1: Edge trace animation
        animatedBox.animateEdgeTrace(duration: BoxAnimationTiming.edgeTrace) { [weak self] in
            guard let self = self else { return }

            // Phase 2: Fly to bottom position
            self.animationPhase = .flyingToBottom

            animatedBox.animateFlyToBottom(duration: BoxAnimationTiming.flyToBottom) { [weak self] in
                guard let self = self else { return }

                // Phase 3: Grow vertical edges
                self.animationPhase = .growingVertical

                animatedBox.animateGrowVertical(duration: BoxAnimationTiming.growVertical) { [weak self] in
                    guard let self = self else { return }

                    // Phase 4: Completion pulse
                    self.animationPhase = .completionPulse

                    animatedBox.animateCompletionPulse(duration: BoxAnimationTiming.completionPulse) { [weak self] in
                        guard let self = self else { return }

                        // Phase 5: Dimension callout
                        self.animationPhase = .dimensionCallout

                        // Prepare adjusted box and result for callout display
                        var adjustedBox = boundingBox
                        if let floorY = floorY {
                            adjustedBox.extendBottomToFloor(floorY: floorY, threshold: self.floorSnapThreshold)
                        }

                        var adjustedResult = self.measurementCalculator.recalculate(
                            boundingBox: adjustedBox,
                            quality: result.quality,
                            axisMapping: result.axisMapping
                        )
                        adjustedResult.pointCloud = result.pointCloud
                        adjustedResult.maskPixelBounds = result.maskPixelBounds
                        #if DEBUG
                        adjustedResult.debugMaskImage = result.debugMaskImage
                        adjustedResult.debugDepthImage = result.debugDepthImage
                        #endif

                        // Populate callout data
                        self.calloutBoxId = self.nextBoxId
                        self.calloutWidth = self.currentUnit.formatDimension(meters: adjustedResult.width)
                        self.calloutHeight = self.currentUnit.formatDimension(meters: adjustedResult.height)
                        self.calloutLength = self.currentUnit.formatDimension(meters: adjustedResult.length)
                        self.calloutLineRevealed = [false, false, false, false]
                        self.calloutTransitionProgress = 0.0
                        self.showDimensionCallout = true

                        // Kick off the VLM description AS EARLY AS POSSIBLE — the
                        // staggered W/H/L reveals + hold + transition together only
                        // give it ~1.3 s before the 2D callout fades out. On-device
                        // VLM inference takes several seconds, so without the head
                        // start the description lands after the callout is gone and
                        // is never displayed.
                        //
                        // Crop priority (each step is a strictly better answer to
                        // "where is the object in this frame?"):
                        //   1. Segmentation mask bbox — what the measurement
                        //      pipeline actually said was the object. Tightest,
                        //      no projection error, guaranteed to enclose what
                        //      the system measured.
                        //   2. 3D-bbox 2D projection — fallback when the mask
                        //      bounds aren't available; may under-include
                        //      protrusions outside the AABB.
                        //   3. Full frame — last resort.
                        if let frame = self.sessionManager.currentFrame {
                            let cropped: UIImage?
                            if let maskBounds = adjustedResult.maskPixelBounds {
                                cropped = self.croppedSnapshotFromMaskBounds(
                                    frame: frame, sensorRect: maskBounds
                                ) ?? self.croppedSnapshotForVLM(frame: frame, bbox: adjustedBox)
                            } else {
                                cropped = self.croppedSnapshotForVLM(frame: frame, bbox: adjustedBox)
                            }
                            if let image = cropped ?? frame.capturedUIImage() {
                                self.startObjectDescription(image: image)
                            }
                        }

                        // Stagger line reveals
                        Task { [weak self] in
                            guard let self = self else { return }
                            let stagger = PMTheme.calloutLineStagger

                            for i in 0..<4 {
                                try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                                guard self.showDimensionCallout else { return }
                                withAnimation(.easeOut(duration: 0.2)) {
                                    self.calloutLineRevealed[i] = true
                                }
                            }

                            // Hold briefly
                            try? await Task.sleep(nanoseconds: UInt64(PMTheme.calloutHoldDuration * 1_000_000_000))
                            guard self.showDimensionCallout else { return }

                            // Phase 6: Transition — swap animated box to real BoxVisualization
                            self.animationPhase = .calloutTransition

                            // Remove animated box, create real visualization
                            if let anchor = self.animatedBoxAnchor {
                                self.sessionManager.removeAnchor(anchor)
                            }
                            self.animatedBoxAnchor = nil
                            self.animatedBoxVisualization = nil

                            self.currentMeasurement = adjustedResult
                            self.showBoxVisualization(for: adjustedBox, pointCloud: result.pointCloud, floorY: floorY, unit: self.currentUnit)
                            // Carry whatever VLM description has already landed
                            // into the freshly-created 3D billboard (it may be
                            // nil if the inference is still running — the VLM
                            // Task will call updateDescription again on finish).
                            self.boxVisualization?.updateDescription(self.objectDescription)

                            // Hide 3D billboard initially
                            self.boxVisualization?.setDimensionBillboardVisible(false)

                            // Compute target screen position — use label billboard top if available
                            let billboardWorldPos: SIMD3<Float>
                            if self.showLabelBillboard, let lb = self.labelBillboard {
                                billboardWorldPos = lb.getTopWorldPosition()
                            } else {
                                billboardWorldPos = adjustedBox.center + SIMD3<Float>(0, adjustedBox.extents.y + 0.03, 0)
                            }
                            if let screenPos = self.sessionManager.projectToScreen(worldPosition: billboardWorldPos) {
                                self.calloutTargetScreenPosition = screenPos
                            } else {
                                // Fallback: screen center
                                let viewSize = self.sessionManager.arView.bounds.size
                                self.calloutTargetScreenPosition = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                            }

                            // Wait for the VLM description to land before shrinking
                            // the 2D callout into the 3D billboard — otherwise the
                            // text never gets a chance to appear. Cap the wait so a
                            // stalled VLM doesn't freeze the UI; give a brief read
                            // pause once the description shows.
                            let descMaxWait: Double = 12.0
                            let descStep: Double = 0.1
                            var descWaited: Double = 0
                            while self.isDescribingObject && descWaited < descMaxWait {
                                try? await Task.sleep(nanoseconds: UInt64(descStep * 1_000_000_000))
                                descWaited += descStep
                                guard self.showDimensionCallout else { return }
                            }
                            if self.objectDescription != nil {
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                guard self.showDimensionCallout else { return }
                            }

                            // Start label billboard expansion concurrently with callout transition
                            if self.showLabelBillboard, let lb = self.labelBillboard {
                                self.boxVisualization?.setDimensionBillboardVisible(false)

                                let qualityLabel = adjustedResult.quality.overallQuality.rawValue
                                let pointCount = adjustedResult.quality.pointCount
                                // Trigger status vignette flash at banner reveal
                                self.statusVignetteIsNG = false
                                self.showStatusVignette = true

                                lb.expandWithDimensions(
                                    height: adjustedResult.height,
                                    length: adjustedResult.length,
                                    width: adjustedResult.width,
                                    unit: self.currentUnit,
                                    boxId: self.nextBoxId,
                                    volume: adjustedBox.volume,
                                    qualityLabel: qualityLabel,
                                    pointCount: pointCount
                                ) { [weak self] in
                                    guard let self = self else { return }
                                    self.animationPhase = .complete
                                    self.isProcessing = false
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)

                                    if self.workflowStep == .awaitingSecondTap {
                                        self.workflowStep = .showingResult
                                    }
                                }
                            }

                            // Animate 2D card toward billboard position
                            withAnimation(.easeInOut(duration: PMTheme.calloutTransitionDuration)) {
                                self.calloutTransitionProgress = 1.0
                            }

                            // Wait for transition to complete
                            try? await Task.sleep(nanoseconds: UInt64(PMTheme.calloutTransitionDuration * 1_000_000_000))

                            // Phase 7: Complete
                            self.showDimensionCallout = false

                            if !self.showLabelBillboard {
                                // Normal flow (no label): show box billboard
                                self.boxVisualization?.setDimensionBillboardVisible(true, forceShow: true)
                                self.animationPhase = .complete
                                self.isProcessing = false

                                if self.workflowStep == .awaitingSecondTap {
                                    self.workflowStep = .showingResult
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func saveMeasurement(mode: MeasurementMode, unit: MeasurementUnit = .centimeters) {
        #if DEBUG
        print("🔴 [ViewModel] saveMeasurement START")
        #endif
        guard let result = currentMeasurement else {
            #if DEBUG
            print("🔴 [ViewModel] No current measurement to save!")
            #endif
            return
        }
        #if DEBUG
        print("🔴 [ViewModel] Has measurement, proceeding...")
        #endif

        // Capture annotated image
        let imageData = captureAnnotatedImage()

        // Create and save measurement (attach pending label data if available)
        let measurement = ProductMeasurement(
            boundingBox: result.boundingBox,
            quality: result.quality,
            mode: mode,
            annotatedImageData: imageData,
            labelData: pendingLabelData
        )
        pendingLabelData = nil

        // Save to SwiftData (will be handled by the view's modelContext)
        NotificationCenter.default.post(
            name: .saveMeasurement,
            object: measurement
        )
        #if DEBUG
        print("🔴 [ViewModel] Posted notification")
        #endif

        // Convert current box to CompletedBoxVisualization (keep it displayed)
        #if DEBUG
        print("🔴 [ViewModel] Calling convertActiveBoxToCompleted...")
        #endif
        convertActiveBoxToCompleted(result: result, unit: unit)
        #if DEBUG
        print("🔴 [ViewModel] convertActiveBoxToCompleted done. Count: \(completedBoxCount)")
        #endif

        // Transfer label billboard ownership to the completed visualization
        if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
           let lastViz = completedBoxVisualizations.last {
            lastViz.attachLabelBillboard(billboard, anchor: anchor)
            // Nil out ViewModel references so clearActiveBoxOnly() won't remove them
            labelBillboard = nil
            labelBillboardAnchor = nil
            showLabelBillboard = false
            #if DEBUG
            print("🔴 [ViewModel] Transferred label billboard to completed viz")
            #endif
        }

        // Clear active box state (but don't call discardMeasurement which removes all)
        #if DEBUG
        print("🔴 [ViewModel] Calling clearActiveBoxOnly...")
        #endif
        clearActiveBoxOnly()
        #if DEBUG
        print("🔴 [ViewModel] saveMeasurement END")
        #endif
    }

    /// Convert the active box to a completed visualization and keep it displayed
    private func convertActiveBoxToCompleted(result: MeasurementCalculator.MeasurementResult, unit: MeasurementUnit) {
        #if DEBUG
        print("[ViewModel] Converting active box to completed visualization")
        print("[ViewModel] Dimensions: H=\(result.height*100)cm, L=\(result.length*100)cm, W=\(result.width*100)cm")
        #endif

        // Remove oldest if at max capacity
        if completedBoxVisualizations.count >= maxCompletedBoxes {
            // Clean up oldest viz's attached label billboard if any
            completedBoxVisualizations.first?.removeAttachedLabelBillboard()
            if let oldAnchor = completedBoxAnchors.first {
                sessionManager.removeAnchor(oldAnchor)
            }
            completedBoxVisualizations.removeFirst()
            completedBoxAnchors.removeFirst()
        }

        // Create completed visualization with dimension labels and re-edit data
        let completedViz = CompletedBoxVisualization(
            boundingBox: result.boundingBox,
            height: result.height,
            length: result.length,
            width: result.width,
            unit: unit,
            boxId: nextBoxId,
            quality: result.quality,
            axisMapping: result.axisMapping,
            pointCloud: result.pointCloud,
            floorY: boxVisualization?.floorY,
            labelData: pendingLabelData
        )
        nextBoxId += 1

        // Add to scene with its own anchor
        let anchor = sessionManager.addEntityWithAnchor(completedViz.entity)
        #if DEBUG
        print("[ViewModel] Added completed box anchor. Total completed boxes: \(completedBoxVisualizations.count + 1)")
        #endif

        completedBoxVisualizations.append(completedViz)
        completedBoxAnchors.append(anchor)
        completedBoxCount = completedBoxVisualizations.count
    }

    /// Clear only the active box, keeping completed boxes
    private func clearActiveBoxOnly() {
        #if DEBUG
        print("[ViewModel] clearActiveBoxOnly called")
        print("[ViewModel] boxVisualizationAnchor exists: \(boxVisualizationAnchor != nil)")
        print("[ViewModel] completedBoxAnchors count: \(completedBoxAnchors.count)")

        // Remove stage point cloud visualizations
        for anchor in stageVisualizationAnchors {
            sessionManager.removeAnchor(anchor)
        }
        stageVisualizationAnchors.removeAll()
        pointCloudCaptures.removeAll()
        selectedVisualizationStage = nil
        #endif

        // Remove active box visualization
        if let anchor = boxVisualizationAnchor {
            sessionManager.removeAnchor(anchor)
            #if DEBUG
            print("[ViewModel] Removed active box anchor")
            #endif
        }
        boxVisualization = nil
        boxVisualizationAnchor = nil
        pointCloudEntity?.removeFromParent()
        pointCloudEntity = nil

        // Remove animation anchor if exists
        if let anchor = animatedBoxAnchor {
            sessionManager.removeAnchor(anchor)
        }
        animatedBoxAnchor = nil
        animatedBoxVisualization = nil

        // Reset active measurement state
        currentMeasurement = nil
        isEditing = false
        isDragging = false
        storedPointCloud = nil
        #if DEBUG
        debugMaskImage = nil
        debugMaskImage2 = nil
        debugDepthImage = nil
        #endif
        animationPhase = .showingTargetBrackets
        animationContext = nil
        animationCoordinator.cancelAnimation()

        // Reset refinement state
        isRefining = false
        refinementCount = 0
        accumulatedPointClouds = []
        accumulatedQualities = []
        originalAxisMapping = nil
        originalFloorY = nil
        isFloorPlaneBacked = false

        // Reset pending first-tap state
        clearPendingFirstTap()

        // Reset reticle lock-on state
        clearReticleState()

        // Reset callout state
        resetCalloutState()

        // Reset workflow state
        workflowStep = .idle

        // Clean up label billboard if present
        if showLabelBillboard {
            showLabelBillboard = false
            labelBillboard?.entity.isEnabled = false
            if let anchor = labelBillboardAnchor {
                sessionManager.removeAnchor(anchor)
            }
            labelBillboardAnchor = nil
            labelBillboard = nil
        }

        // Clean up lift animation if present (may survive if billboard path was used)
        if let anchor = labelLiftAnchor {
            sessionManager.removeAnchor(anchor)
        }
        labelLiftAnchor = nil
        labelLiftAnimation = nil

        // Reset label processing flags
        currentLabelData = nil
        pendingLabelData = nil
        isReadingLabel = false
        showBarcodeScanEffect = false
        correctedLabelImage = nil

        #if DEBUG
        print("[ViewModel] clearActiveBoxOnly completed. Completed boxes preserved: \(completedBoxAnchors.count)")
        #endif
    }

    /// Clear all completed boxes from the scene
    func clearAllMeasurements() {
        for viz in completedBoxVisualizations {
            viz.removeAttachedLabelBillboard()
        }
        for anchor in completedBoxAnchors {
            sessionManager.removeAnchor(anchor)
        }
        completedBoxVisualizations.removeAll()
        completedBoxAnchors.removeAll()
        completedBoxCount = 0
        nextBoxId = 1
        clearPendingFirstTap()
    }

    func startEditing() {
        isEditing = true
        boxVisualization?.isInteractive = true
        boxVisualization?.updateActionMode(.editing)
        if labelBillboard?.isUnified == true {
            labelBillboard?.updateActionIcons(ActionIconBuilder.activeEditActions)
        }
    }

    func stopEditing() {
        isEditing = false
        isDragging = false
        boxVisualization?.isInteractive = false
        if boxVisualization?.isExpandedWithLabel == true {
            let mode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                ? .labelExpandedNoRefine : .labelExpanded
            boxVisualization?.updateActionMode(mode)
        } else {
            boxVisualization?.updateActionMode(.normal)
        }
        if labelBillboard?.isUnified == true {
            let actions = refinementCount >= AppConstants.maxRefinementRounds
                ? ActionIconBuilder.labelUnifiedNoRefineActions
                : ActionIconBuilder.labelUnifiedActions
            labelBillboard?.updateActionIcons(actions)
        }
    }

    func handleFaceDrag(handleType: HandleType, screenDelta: CGPoint, mode: MeasurementMode) {
        guard let result = currentMeasurement else { return }

        isDragging = true

        // Highlight the touched handle
        boxVisualization?.highlightHandle(handleType)

        // Get face center position in world space (not handle position)
        // This gives us the correct direction for the face normal on screen
        guard let faceCenterLocalPos = handleType.faceCenterPosition(extents: result.boundingBox.extents) else {
            return
        }
        let faceCenterWorldPos = result.boundingBox.localToWorld(faceCenterLocalPos)

        // Project face center and box center to screen coordinates
        guard let faceCenterScreenPos = sessionManager.projectToScreen(worldPosition: faceCenterWorldPos),
              let boxCenterScreenPos = sessionManager.projectToScreen(worldPosition: result.boundingBox.center) else {
            return
        }

        // Apply face drag to bounding box
        let editResult = boxEditingService.applyFaceDrag(
            box: result.boundingBox,
            handleType: handleType,
            screenDelta: screenDelta,
            faceCenterScreenPos: faceCenterScreenPos,
            boxCenterScreenPos: boxCenterScreenPos
        )

        if editResult.didChange {
            // Update measurement result using the original axis mapping
            let newResult = measurementCalculator.recalculate(
                boundingBox: editResult.boundingBox,
                quality: result.quality,
                axisMapping: result.axisMapping
            )
            var updatedResult = newResult
            updatedResult.pointCloud = storedPointCloud
            #if DEBUG
            updatedResult.debugMaskImage = result.debugMaskImage
            updatedResult.debugDepthImage = result.debugDepthImage
            #endif
            currentMeasurement = updatedResult

            // Update visualization
            boxVisualization?.update(boundingBox: editResult.boundingBox)
            boxVisualization?.updateDimensions(
                height: updatedResult.height,
                length: updatedResult.length,
                width: updatedResult.width
            )
        }
    }

    func handleRotationDrag(screenDelta: CGPoint, touchLocation: CGPoint) {
        guard let result = currentMeasurement else { return }

        isDragging = true

        // Highlight the rotation handle
        boxVisualization?.highlightRotationHandle()

        // Project box center to screen
        guard let boxCenterScreenPos = sessionManager.projectToScreen(worldPosition: result.boundingBox.center) else {
            return
        }

        // Calculate vector from box center to touch location
        let toTouch = SIMD2<Float>(
            Float(touchLocation.x - boxCenterScreenPos.x),
            Float(touchLocation.y - boxCenterScreenPos.y)
        )
        let touchDistance = simd_length(toTouch)

        // If touch is too close to center, can't determine rotation
        guard touchDistance > 10 else { return }

        // Calculate tangent direction (perpendicular to radial, clockwise)
        // For screen coordinates (Y down), clockwise tangent is (toTouch.y, -toTouch.x)
        let tangent = SIMD2<Float>(toTouch.y, -toTouch.x) / touchDistance

        // Project screen delta onto tangent direction
        // Positive = clockwise rotation on screen
        let screenDelta2D = SIMD2<Float>(Float(screenDelta.x), Float(screenDelta.y))
        let tangentialDelta = simd_dot(screenDelta2D, tangent)

        // Convert to world Y rotation
        // When looking from above (camera Y+), clockwise screen rotation = negative Y rotation
        // Scale by distance to get consistent angular speed
        let angularScale: Float = 1.0 / touchDistance
        let yawAngle = tangentialDelta * angularScale

        // Apply rotation
        var newBox = result.boundingBox
        newBox.rotateAroundY(by: yawAngle)

        // Update measurement result using the original axis mapping
        let newResult = measurementCalculator.recalculate(
            boundingBox: newBox,
            quality: result.quality,
            axisMapping: result.axisMapping
        )
        var updatedResult = newResult
        updatedResult.pointCloud = storedPointCloud
        #if DEBUG
        updatedResult.debugMaskImage = result.debugMaskImage
        updatedResult.debugDepthImage = result.debugDepthImage
        #endif
        currentMeasurement = updatedResult

        // Update visualization
        boxVisualization?.update(boundingBox: newBox)
        boxVisualization?.updateDimensions(
            height: updatedResult.height,
            length: updatedResult.length,
            width: updatedResult.width
        )
    }

    func finishDrag() {
        isDragging = false
        // Remove handle highlight
        boxVisualization?.unhighlightAllHandles()
    }

    func fitToPointCloud(mode: MeasurementMode) {
        guard let result = currentMeasurement,
              let points = storedPointCloud,
              !points.isEmpty else {
            #if DEBUG
            print("[ViewModel] No point cloud available for fit")
            #endif
            return
        }

        #if DEBUG
        print("[ViewModel] Fitting to point cloud with \(points.count) points")
        #endif

        if var fittedBox = boxEditingService.fitToPoints(
            currentBox: result.boundingBox,
            allPoints: points,
            mode: mode
        ) {
            // Apply bottom extension if within threshold of floor
            if let floorY = boxVisualization?.floorY {
                fittedBox.extendBottomToFloor(floorY: floorY, threshold: floorSnapThreshold)
            }

            // Update measurement result using the original axis mapping
            let newResult = measurementCalculator.recalculate(
                boundingBox: fittedBox,
                quality: result.quality,
                axisMapping: result.axisMapping
            )
            var updatedResult = newResult
            updatedResult.pointCloud = storedPointCloud
            #if DEBUG
            updatedResult.debugMaskImage = result.debugMaskImage
            updatedResult.debugDepthImage = result.debugDepthImage
            #endif
            currentMeasurement = updatedResult

            // Update visualization
            boxVisualization?.update(boundingBox: fittedBox)
            boxVisualization?.updateDimensions(
                height: updatedResult.height,
                length: updatedResult.length,
                width: updatedResult.width
            )

            #if DEBUG
            print("[ViewModel] Fit successful - new dimensions: L=\(fittedBox.length*100)cm, W=\(fittedBox.width*100)cm, H=\(fittedBox.height*100)cm")
            #endif
        } else {
            #if DEBUG
            print("[ViewModel] Fit failed - not enough points in current box")
            #endif
        }
    }

    // MARK: - Action Icon Handling

    /// Handle tap on a 3D action icon
    func handleActionTap(_ actionType: ActionType, mode: MeasurementMode) {
        switch actionType {
        case .save:
            stopEditing()
            saveMeasurement(mode: mode, unit: currentUnit)
        case .edit:
            startEditing()
        case .discard:
            discardMeasurement()
        case .done:
            stopEditing()
        case .fit:
            fitToPointCloud(mode: mode)
        case .cancel:
            if isRefining { cancelRefinement() } else { discardMeasurement() }
        case .reEdit:
            reEditCompletedBox()
        case .delete:
            deleteCompletedBox()
        case .refine:
            startRefinementMode()
        case .labelDone:
            dismissLabelResult()
        case .labelRescan:
            resetLabelScan()
        }
    }

    // MARK: - Refinement

    private func startRefinementMode() {
        guard let result = currentMeasurement else { return }

        // Save original axis mapping and floor on first refinement
        if originalAxisMapping == nil {
            originalAxisMapping = result.axisMapping
        }
        if originalFloorY == nil {
            originalFloorY = boxVisualization?.floorY
        }

        // Seed accumulated point clouds with current data
        if accumulatedPointClouds.isEmpty, let pc = storedPointCloud {
            accumulatedPointClouds = [pc]
            accumulatedQualities = [result.quality]
        }

        isRefining = true
        boxVisualization?.updateActionMode(.refining)
        if labelBillboard?.isUnified == true {
            labelBillboard?.updateActionIcons(ActionIconBuilder.activeRefiningActions)
        }
        #if DEBUG
        print("[Refine] Entered refinement mode (round \(refinementCount + 1))")
        #endif
    }

    private func cancelRefinement() {
        isRefining = false
        if boxVisualization?.isExpandedWithLabel == true {
            let mode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                ? .labelExpandedNoRefine : .labelExpanded
            boxVisualization?.updateActionMode(mode)
        } else {
            let mode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                ? .normalNoRefine : .normal
            boxVisualization?.updateActionMode(mode)
        }
        if labelBillboard?.isUnified == true {
            let actions = refinementCount >= AppConstants.maxRefinementRounds
                ? ActionIconBuilder.labelUnifiedNoRefineActions
                : ActionIconBuilder.labelUnifiedActions
            labelBillboard?.updateActionIcons(actions)
        }
        #if DEBUG
        print("[Refine] Cancelled refinement mode")
        #endif
    }

    /// Clear pending first-tap state
    private func clearPendingFirstTap() {
        pendingFirstTapResult = nil
        pendingFirstTapFloorY = nil
        pendingFirstTapFloorPlaneBacked = false
        hasPendingFirstTap = false
        secondTapAttemptCount = 0
        secondTapFailureMessage = nil
    }

    func handleRefinementTap(at location: CGPoint, mode: MeasurementMode) async {
        guard let result = currentMeasurement,
              let frame = sessionManager.currentFrame else { return }
        guard !isProcessing else { return }

        isProcessing = true
        let viewSize = sessionManager.arView.bounds.size
        let raycastHitPosition = sessionManager.raycastWorldPosition(from: location)

        do {
            if let refinement = try await measurementCalculator.measureForRefinement(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize,
                mode: mode,
                existingBox: result.boundingBox,
                raycastHitPosition: raycastHitPosition
            ) {
                // Success: merge point clouds and re-estimate
                accumulatedPointClouds.append(refinement.points)
                accumulatedQualities.append(refinement.quality)
                refinementCount += 1

                let mergedPoints = accumulatedPointClouds.flatMap { $0 }
                let mergedQuality = MeasurementQuality.merged(accumulatedQualities)

                // Re-estimate bounding box from merged points
                let verticalPlanes = frame.anchors.compactMap { anchor -> ARPlaneAnchor? in
                    guard let plane = anchor as? ARPlaneAnchor, plane.alignment == .vertical else { return nil }
                    return plane
                }

                guard let newBox = BoundingBoxEstimator().estimateBoundingBox(
                    points: mergedPoints, mode: mode, verticalPlaneAnchors: verticalPlanes
                ) else {
                    #if DEBUG
                    print("[Refine] Re-estimation failed")
                    #endif
                    isProcessing = false
                    return
                }

                // Apply floor extension
                var adjustedBox = newBox
                if let floorY = originalFloorY {
                    adjustedBox.extendBottomToFloor(floorY: floorY, threshold: floorSnapThreshold)
                }

                // Recalculate with original axis mapping
                let mapping = originalAxisMapping ?? result.axisMapping
                var newResult = measurementCalculator.recalculate(
                    boundingBox: adjustedBox, quality: mergedQuality, axisMapping: mapping
                )
                newResult.pointCloud = mergedPoints
                currentMeasurement = newResult
                storedPointCloud = mergedPoints

                // Update visualization
                boxVisualization?.update(boundingBox: adjustedBox)
                boxVisualization?.updateDimensions(
                    height: newResult.height, length: newResult.length, width: newResult.width
                )

                // Exit refinement mode
                isRefining = false
                let actionMode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                    ? .normalNoRefine : .normal
                boxVisualization?.updateActionMode(actionMode)

                #if DEBUG
                print("[Refine] Refinement \(refinementCount) complete. Dimensions: L=\(newResult.length*100)cm W=\(newResult.width*100)cm H=\(newResult.height*100)cm")
                #endif
            } else {
                #if DEBUG
                print("[Refine] Object not matched – stay in refinement mode")
                #endif
                // Could show a transient message here in the future
            }
        } catch {
            #if DEBUG
            print("[Refine] Error: \(error)")
            #endif
        }

        isProcessing = false
    }

    // MARK: - Label Reader

    func handleLabelTap(at location: CGPoint) async {
        guard !isProcessing, !isReadingLabel else {
            #if DEBUG
            print("[LabelReader] Already processing, ignoring tap")
            #endif
            return
        }

        guard let frame = sessionManager.currentFrame else {
            #if DEBUG
            print("[LabelReader] No current frame")
            #endif
            return
        }

        isReadingLabel = true
        isProcessing = true

        let viewSize = sessionManager.arView.bounds.size

        do {
            guard let result = try await labelReaderService.detectAndReadLabel(
                frame: frame,
                tapPoint: location,
                viewSize: viewSize
            ) else {
                #if DEBUG
                print("[LabelReader] No label detected near tap point")
                #endif
                isProcessing = false
                isReadingLabel = false
                showTemporaryError(String(localized: "No label detected. Try again."))
                return
            }

            #if DEBUG
            print("[LabelReader] Label detected, starting lift animation")
            #endif

            // Refine world corners with raycast on main thread (more accurate than depth map)
            let refinedCorners: [SIMD3<Float>]? = {
                guard let quad = result.worldCorners, quad.count == 4 else { return result.worldCorners }
                let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
                let visionCorners = [
                    result.quadrilateral.topLeft,
                    result.quadrilateral.topRight,
                    result.quadrilateral.bottomRight,
                    result.quadrilateral.bottomLeft
                ]
                var corners: [SIMD3<Float>] = []
                for vc in visionCorners {
                    // Vision (.right) → normalized image coords → screen coords
                    let imageNorm = CGPoint(x: CGFloat(vc.y), y: 1.0 - CGFloat(vc.x))
                    let screenNorm = imageNorm.applying(displayTransform)
                    let screenPoint = CGPoint(x: screenNorm.x * viewSize.width, y: screenNorm.y * viewSize.height)
                    let hits = sessionManager.arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
                    if let hit = hits.first {
                        let pos = hit.worldTransform.columns.3
                        corners.append(SIMD3<Float>(pos.x, pos.y, pos.z))
                    } else {
                        #if DEBUG
                        print("[LabelReader] Raycast miss, using depth map corners")
                        #endif
                        return result.worldCorners
                    }
                }
                #if DEBUG
                print("[LabelReader] World corners refined by raycast")
                #endif
                return corners
            }()

            // Create lift animation
            let liftAnim = LabelLiftAnimation()
            let raycastPos = sessionManager.raycastWorldPosition(from: location)
            liftAnim.setup(
                labelImage: result.correctedImage,
                worldCorners: refinedCorners,
                surfaceNormal: result.surfaceNormal,
                cameraTransform: frame.camera.transform,
                fallbackPosition: raycastPos
            )

            labelLiftAnimation = liftAnim
            labelLiftAnchor = sessionManager.addEntityWithAnchor(liftAnim.entity)

            // Animate
            let cameraTransform = frame.camera.transform
            liftAnim.animate(cameraTransform: cameraTransform) { [weak self] in
                guard let self = self else { return }

                // Lift complete - hide 3D, show 2D image, start barcode scan effect
                self.currentLabelData = result.labelData
                self.correctedLabelImageSize = result.correctedImage.size
                self.correctedLabelImage = result.correctedImage
                self.labelLiftAnimation?.setVisible(false)
                self.isProcessing = false
                self.showBarcodeScanEffect = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            #if DEBUG
            print("[LabelReader] Error: \(error)")
            #endif
            isProcessing = false
            isReadingLabel = false
        }
    }

    func barcodeScanEffectCompleted() {
        showBarcodeScanEffect = false
        correctedLabelImage = nil
        isReadingLabel = false

        guard let labelData = currentLabelData,
              let liftAnim = labelLiftAnimation else {
            // Fallback to 2D overlay if we can't create billboard
            showLabelResult2D()
            return
        }

        // Expand BoxVisualization billboard with label data if active box exists
        if let boxViz = boxVisualization {
            // Show the lifted label again so it can transition back
            liftAnim.setVisible(true)

            // Phase A: Label shrinks back toward original position
            liftAnim.transitionToOrigin { [weak self] in
                guard let self = self else { return }
                if let liftAnchor = self.labelLiftAnchor {
                    self.sessionManager.removeAnchor(liftAnchor)
                }
                self.labelLiftAnchor = nil
                self.labelLiftAnimation = nil
            }

            // Store label data
            pendingLabelData = labelData

            // Trigger status vignette flash
            statusVignetteIsNG = false
            showStatusVignette = true

            // Phase B: Expand box billboard with label data at 0.3s delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                boxViz.expandWithLabelData(
                    labelData,
                    boxId: self.nextBoxId,
                    volume: self.currentMeasurement?.boundingBox.volume ?? 0
                ) { [weak self] in
                    // Label data attached — no workflow transition needed
                    _ = self
                }
            }
            return
        }

        // No active box: create separate LabelBillboard

        // Show the lifted label again so it can transition back
        liftAnim.setVisible(true)

        // Create billboard at label's original position + offset above surface
        let billboardPosition = liftAnim.originalCenter + liftAnim.originalSurfaceNormal * 0.06
        let billboard = LabelBillboard(
            labelData: labelData,
            worldPosition: billboardPosition,
            surfaceNormal: liftAnim.originalSurfaceNormal
        )
        labelBillboard = billboard

        // Add billboard to AR scene (hidden initially, reveal starts after overlap)
        let anchor = sessionManager.addEntityWithAnchor(billboard.entity)
        labelBillboardAnchor = anchor
        billboard.setVisible(false)

        showLabelBillboard = true

        // Phase A: Label shrinks back toward original position (0–0.8s)
        liftAnim.transitionToOrigin { [weak self] in
            guard let self = self else { return }
            // Label transition complete — remove lift animation
            if let liftAnchor = self.labelLiftAnchor {
                self.sessionManager.removeAnchor(liftAnchor)
            }
            self.labelLiftAnchor = nil
            self.labelLiftAnimation = nil
        }

        // Phase B: Billboard appears at 0.3s overlap (while label still shrinking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.showLabelBillboard else { return }
            billboard.setVisible(true)
            billboard.startRevealAnimation { [weak self] in
                guard let self = self else { return }
                // Store label data — no workflow transition needed
                self.pendingLabelData = self.currentLabelData
            }
        }
    }

    /// Fallback: show 2D SwiftUI overlay if billboard creation fails
    private func showLabelResult2D() {
        labelLiftAnimation?.setVisible(true)

        let fields = currentLabelData?.displayFields ?? []
        labelLineRevealed = Array(repeating: false, count: max(fields.count, 1))
        showLabelResult = true
        labelReadingComplete = false

        Task { [weak self] in
            guard let self = self else { return }
            let count = max(fields.count, 1)
            let stagger = PMTheme.labelTypingStagger

            for i in 0..<count {
                try? await Task.sleep(nanoseconds: UInt64(stagger * 1_000_000_000))
                guard self.showLabelResult else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    if i < self.labelLineRevealed.count {
                        self.labelLineRevealed[i] = true
                    }
                }
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.2)) {
                self.labelReadingComplete = true
            }
        }
    }

    func dismissLabelResult() {
        showLabelResult = false
        correctedLabelImage = nil

        // Store label data for next measurement
        pendingLabelData = currentLabelData

        // Dismiss AR billboard if showing
        if showLabelBillboard, let billboard = labelBillboard {
            showLabelBillboard = false
            billboard.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelBillboardAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelBillboardAnchor = nil
                self.labelBillboard = nil
            }
        }

        // Dismiss lift animation (may already be nil if billboard was used)
        if let liftAnim = labelLiftAnimation {
            liftAnim.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelLiftAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelLiftAnchor = nil
                self.labelLiftAnimation = nil
            }
        }

        // Reset label state
        currentLabelData = nil
        labelLineRevealed = []
        labelReadingComplete = false
        isReadingLabel = false

        // Advance workflow if active
        if isWorkflowActive {
            workflowStep = .showingResult
        }
    }

    // MARK: - Workflow Methods

    func resetLabelScan() {
        // Cancel barcode scan effect
        showBarcodeScanEffect = false

        // Dismiss label result
        showLabelResult = false

        // Collapse expanded box billboard back to dimensions-only
        if boxVisualization?.isExpandedWithLabel == true {
            boxVisualization?.collapseLabelSection()
            let mode: BoxVisualization.ActionMode = refinementCount >= AppConstants.maxRefinementRounds
                ? .normalNoRefine : .normal
            boxVisualization?.updateActionMode(mode)
            pendingLabelData = nil
        }

        // Dismiss AR billboard if showing
        if showLabelBillboard {
            showLabelBillboard = false
            labelBillboard?.entity.isEnabled = false
            if let anchor = labelBillboardAnchor {
                sessionManager.removeAnchor(anchor)
            }
            labelBillboardAnchor = nil
            labelBillboard = nil
        }

        // Dismiss lift animation immediately
        if let liftAnim = labelLiftAnimation {
            liftAnim.dismiss { [weak self] in
                guard let self = self else { return }
                if let anchor = self.labelLiftAnchor {
                    self.sessionManager.removeAnchor(anchor)
                }
                self.labelLiftAnchor = nil
                self.labelLiftAnimation = nil
            }
        }

        // Reset all label state
        currentLabelData = nil
        correctedLabelImage = nil
        correctedLabelImageSize = .zero
        labelLineRevealed = []
        labelReadingComplete = false
        isReadingLabel = false
        isProcessing = false

        // Label scan reset does not change workflow step
    }

    func closeWorkflow() {
        workflowStep = .idle
    }

    func resetForNewMeasurement() {
        clearActiveBoxOnly()
        workflowStep = .idle
    }

    // MARK: - Error Feedback

    // MARK: - Ghost Box (first-tap preview)

    private func showGhostBox(for boundingBox: BoundingBox3D) {
        let edges = boundingBox.edges
        let corners = boundingBox.corners
        let edgeRadius = PMTheme.innerEdgeRadius
        let cornerRadius = PMTheme.cornerMarkerRadiusSmall

        // Reuse existing entities if box structure matches (always 12 edges, 8 corners)
        let canReuse = ghostBoxAnchor != nil
            && ghostEdgeEntities.count == edges.count
            && ghostCornerEntities.count == corners.count

        if canReuse {
            // Animate existing entities to new transforms
            for (i, edge) in edges.enumerated() {
                let start = edge.0
                let end = edge.1
                let mid = (start + end) / 2.0
                let length = simd_distance(start, end)
                guard length > 0.0001 else { continue }

                var newTransform = ghostEdgeEntities[i].transform
                newTransform.translation = mid
                let direction = simd_normalize(end - start)
                let defaultDir = SIMD3<Float>(0, 0, 1)
                newTransform.rotation = simd_quaternion(defaultDir, direction)
                // Scale Z to match new length (mesh is unit-length)
                newTransform.scale = SIMD3<Float>(1, 1, length)

                ghostEdgeEntities[i].move(
                    to: newTransform,
                    relativeTo: ghostEdgeEntities[i].parent,
                    duration: 0.35,
                    timingFunction: .easeInOut
                )
            }
            for (i, corner) in corners.enumerated() {
                var newTransform = ghostCornerEntities[i].transform
                newTransform.translation = corner
                ghostCornerEntities[i].move(
                    to: newTransform,
                    relativeTo: ghostCornerEntities[i].parent,
                    duration: 0.35,
                    timingFunction: .easeInOut
                )
            }
            return
        }

        // First appearance: build fresh hierarchy
        removeGhostBox()
        let container = Entity()
        let unitMesh = MeshResource.generateBox(size: SIMD3<Float>(edgeRadius, edgeRadius, 1.0))
        let edgeMaterial = UnlitMaterial(color: PMTheme.uiGreen)

        for edge in edges {
            let start = edge.0
            let end = edge.1
            let mid = (start + end) / 2.0
            let length = simd_distance(start, end)
            guard length > 0.0001 else { continue }

            let edgeEntity = ModelEntity(mesh: unitMesh, materials: [edgeMaterial])
            edgeEntity.position = mid
            let direction = simd_normalize(end - start)
            let defaultDir = SIMD3<Float>(0, 0, 1)
            edgeEntity.orientation = simd_quaternion(defaultDir, direction)
            edgeEntity.scale = SIMD3<Float>(1, 1, length)
            container.addChild(edgeEntity)
            ghostEdgeEntities.append(edgeEntity)
        }

        let sphereMesh = MeshResource.generateSphere(radius: cornerRadius)
        let sphereMat = UnlitMaterial(color: PMTheme.uiGreen)
        for corner in corners {
            let sphereEntity = ModelEntity(mesh: sphereMesh, materials: [sphereMat])
            sphereEntity.position = corner
            container.addChild(sphereEntity)
            ghostCornerEntities.append(sphereEntity)
        }

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(container)
        sessionManager.arView.scene.addAnchor(anchor)
        ghostBoxAnchor = anchor

        // Subtle scale fade-in on first appearance
        container.scale = SIMD3<Float>(repeating: 0.92)
        var fadeInTransform = container.transform
        fadeInTransform.scale = SIMD3<Float>(repeating: 1.0)
        container.move(to: fadeInTransform, relativeTo: container.parent, duration: 0.35, timingFunction: .easeOut)
    }

    private func removeGhostBox() {
        ghostBoxAnchor?.removeFromParent()
        ghostBoxAnchor = nil
        ghostEdgeEntities.removeAll(keepingCapacity: false)
        ghostCornerEntities.removeAll(keepingCapacity: false)
    }

    // MARK: - Tap Indicator

    private func showTapIndicator(at point: CGPoint) {
        tapIndicatorPosition = point
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.tapIndicatorPosition == point {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.tapIndicatorPosition = nil
                }
            }
        }
    }

    private func guidedErrorMessage() -> String {
        // Provide specific guidance based on current conditions
        if smoothedCenterDepth > 2.5 {
            return String(localized: "Too far. Move closer to the object.")
        }
        if smoothedCenterDepth < 0.2 {
            return String(localized: "Too close. Move back a little.")
        }
        if !isTrackingReady {
            return String(localized: "Tracking unstable. Hold steady and try again.")
        }
        return String(localized: "Measurement failed. Try a different angle.")
    }

    private func showTemporaryError(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        measurementError = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.measurementError == message {
                self.measurementError = nil
            }
        }
    }

    func saveAndReset(mode: MeasurementMode, unit: MeasurementUnit) {
        if currentMeasurement != nil {
            saveMeasurement(mode: mode, unit: unit)
        }
        workflowStep = .idle
    }

    /// Find the completed box ID that owns a given entity
    func findCompletedBoxId(for entity: Entity) -> Int? {
        for viz in completedBoxVisualizations {
            // Walk up from the entity to check if it belongs to this visualization
            var current: Entity? = entity
            while let node = current {
                if node === viz.entity {
                    return viz.id
                }
                // Also check if it belongs to the attached label billboard
                if let labelBB = viz.attachedLabelBillboard, node === labelBB.entity {
                    return viz.id
                }
                current = node.parent
            }
        }
        return nil
    }

    /// Show action icons on a completed box
    func showCompletedBoxActions(boxId: Int) {
        // Dismiss any existing actions first
        dismissCompletedBoxActions()

        selectedCompletedBoxId = boxId
        if let viz = completedBoxVisualizations.first(where: { $0.id == boxId }) {
            viz.showActionIcons()
        }
    }

    /// Dismiss action icons on completed boxes
    func dismissCompletedBoxActions() {
        if let selectedId = selectedCompletedBoxId,
           let viz = completedBoxVisualizations.first(where: { $0.id == selectedId }) {
            viz.hideActionIcons()
        }
        selectedCompletedBoxId = nil
    }

    /// Re-edit a completed box (make it active again)
    private func reEditCompletedBox() {
        guard let selectedId = selectedCompletedBoxId,
              let index = completedBoxVisualizations.firstIndex(where: { $0.id == selectedId }) else {
            return
        }

        let completedViz = completedBoxVisualizations[index]

        // Auto-save current active box if exists
        if let existingResult = currentMeasurement {
            convertActiveBoxToCompleted(result: existingResult, unit: currentUnit)
            // Transfer current active billboard to newly completed viz
            if showLabelBillboard, let billboard = labelBillboard, let anchor = labelBillboardAnchor,
               let lastViz = completedBoxVisualizations.last {
                lastViz.attachLabelBillboard(billboard, anchor: anchor)
                labelBillboard = nil
                labelBillboardAnchor = nil
                showLabelBillboard = false
            }
            clearActiveBoxOnly()
        }

        // Transfer label billboard back to ViewModel if attached
        if let (billboard, bbAnchor) = completedViz.detachLabelBillboard() {
            labelBillboard = billboard
            labelBillboardAnchor = bbAnchor
            showLabelBillboard = true
            // Restore active unified action icons
            billboard.updateActionIcons(ActionIconBuilder.labelUnifiedActions)
        }

        // Get data from completed box
        let result = completedViz.toMeasurementResult()
        let floorY = completedViz.floorY
        let pointCloud = completedViz.pointCloud

        // Remove the completed box from scene
        let anchor = completedBoxAnchors[index]
        sessionManager.removeAnchor(anchor)
        completedBoxVisualizations.remove(at: index)
        completedBoxAnchors.remove(at: index)
        completedBoxCount = completedBoxVisualizations.count
        selectedCompletedBoxId = nil

        // Set as current measurement and show editable box
        currentMeasurement = result
        showBoxVisualization(for: result.boundingBox, pointCloud: pointCloud, floorY: floorY, unit: currentUnit)
        animationPhase = .complete

        // Enter editing mode
        startEditing()
    }

    /// Delete a specific completed box
    private func deleteCompletedBox() {
        guard let selectedId = selectedCompletedBoxId,
              let index = completedBoxVisualizations.firstIndex(where: { $0.id == selectedId }) else {
            return
        }

        // Clean up attached label billboard if any
        completedBoxVisualizations[index].removeAttachedLabelBillboard()

        let anchor = completedBoxAnchors[index]
        sessionManager.removeAnchor(anchor)
        completedBoxVisualizations.remove(at: index)
        completedBoxAnchors.remove(at: index)
        completedBoxCount = completedBoxVisualizations.count
        selectedCompletedBoxId = nil
    }

    func discardMeasurement() {
        // Only discard the active box, not completed boxes
        clearActiveBoxOnly()
    }

    #if DEBUG
    func toggleDebugMask() {
        showDebugMask.toggle()
    }

    func toggleDebugDepth() {
        showDebugDepth.toggle()
    }

    /// Capture diagnostics from the last pipeline run
    private func captureDiagnostics() {
        lastPipelineDiagnostics = measurementCalculator.lastDiagnostics
        if let capture = measurementCalculator.lastPointCloudCapture {
            pointCloudCaptures.append(capture)
        }
        // Auto-show point cloud after measurement
        if showPointCloudViz, !pointCloudCaptures.isEmpty {
            let latest = pointCloudCaptures.last!
            // Pick best available stage: clustering > proximity > downsample
            let stage: PipelinePointCloudCapture.Stage
            if latest.keptCount(at: .afterClustering) > 0 {
                stage = .afterClustering
            } else if latest.keptCount(at: .afterProximityFilter) > 0 {
                stage = .afterProximityFilter
            } else {
                stage = .after3DDownsample
            }
            updateStageVisualization(stage: stage)
        }
    }

    /// Show or clear stage point cloud visualization in AR scene
    func updateStageVisualization(stage: PipelinePointCloudCapture.Stage?) {
        // Remove previous visualizations
        for anchor in stageVisualizationAnchors {
            sessionManager.removeAnchor(anchor)
        }
        stageVisualizationAnchors.removeAll()

        selectedVisualizationStage = stage

        guard let stage = stage else { return }

        // Render all captured taps
        for (i, capture) in pointCloudCaptures.enumerated() {
            let entity = StagePointCloudRenderer.createStageEntity(capture: capture, stage: stage)
            let anchor = sessionManager.addEntityWithAnchor(entity)
            stageVisualizationAnchors.append(anchor)
            print("[StageViz] Tap \(i+1) '\(stage.displayName)': \(entity.children.count) entities")
        }
    }

    /// Toggle point cloud visualization, cycling through stages
    func togglePointCloudViz() {
        if !showPointCloudViz {
            // Turn on — show best available stage
            showPointCloudViz = true
            if let latest = pointCloudCaptures.last {
                let stage: PipelinePointCloudCapture.Stage
                if latest.keptCount(at: .afterClustering) > 0 {
                    stage = .afterClustering
                } else if latest.keptCount(at: .afterProximityFilter) > 0 {
                    stage = .afterProximityFilter
                } else {
                    stage = .after3DDownsample
                }
                updateStageVisualization(stage: stage)
            }
        } else if let current = selectedVisualizationStage {
            // Cycle to next stage
            let allStages = PipelinePointCloudCapture.Stage.allCases
            if let idx = allStages.firstIndex(of: current), idx + 1 < allStages.count {
                let next = allStages[idx + 1]
                // Skip stages with no data (check any capture)
                let hasData = pointCloudCaptures.contains { $0.keptCount(at: next) > 0 }
                if hasData {
                    updateStageVisualization(stage: next)
                    return
                }
            }
            // Wrapped around or no more data — turn off
            showPointCloudViz = false
            updateStageVisualization(stage: nil)
        } else {
            showPointCloudViz = false
            updateStageVisualization(stage: nil)
        }
    }
    #endif

    private func showBoxVisualization(for box: BoundingBox3D, pointCloud: [SIMD3<Float>]? = nil, floorY: Float? = nil, unit: MeasurementUnit = .centimeters) {
        // Store point cloud for Fit functionality
        storedPointCloud = pointCloud

        boxVisualization = BoxVisualization(boundingBox: box, interactive: false)

        // Set floor height for distance indicator
        if let floorY = floorY {
            boxVisualization?.floorY = floorY
        }

        // Set dimensions for labels on the wireframe
        if let result = currentMeasurement {
            boxVisualization?.setDimensions(
                height: result.height,
                length: result.length,
                width: result.width,
                unit: unit,
                boxId: nextBoxId,
                qualityLabel: result.quality.overallQuality.rawValue.capitalized,
                pointCount: result.quality.pointCount,
                labelData: pendingLabelData
            )
        }

        if let entity = boxVisualization?.entity {
            boxVisualizationAnchor = sessionManager.addEntityWithAnchor(entity)
        }
    }

    #if DEBUG
    private func showPointCloudVisualization(points: [SIMD3<Float>]) {
        pointCloudEntity = DebugVisualization.createPointCloudEntity(
            points: points,
            color: .cyan,
            pointSize: 0.003
        )
        if let entity = pointCloudEntity {
            sessionManager.addEntity(entity)
        }
    }

    private func showCameraAxes(transform: simd_float4x4) {
        let axesEntity = DebugVisualization.createAxesEntity(at: transform, length: 0.05)
        sessionManager.addEntity(axesEntity)
    }
    #endif

    /// Remove active visualizations but preserve completed boxes
    private func removeAllVisualizations() {
        #if DEBUG
        print("[ViewModel] removeAllVisualizations called. Completed boxes: \(completedBoxAnchors.count)")
        #endif

        // Remove active box anchor if exists
        if let anchor = boxVisualizationAnchor {
            sessionManager.removeAnchor(anchor)
            #if DEBUG
            print("[ViewModel] Removed active box anchor")
            #endif
        }
        boxVisualization = nil
        boxVisualizationAnchor = nil

        // Remove animation anchor if exists
        if let anchor = animatedBoxAnchor {
            sessionManager.removeAnchor(anchor)
            #if DEBUG
            print("[ViewModel] Removed animation anchor")
            #endif
        }
        animatedBoxAnchor = nil
        animatedBoxVisualization = nil

        pointCloudEntity?.removeFromParent()
        pointCloudEntity = nil
        #if DEBUG
        print("[ViewModel] Completed boxes preserved: \(completedBoxAnchors.count)")
        #endif
    }

    /// Reset all callout-related state
    private func resetCalloutState() {
        showDimensionCallout = false
        calloutLineRevealed = [false, false, false, false]
        calloutTransitionProgress = 0.0
        objectDescription = nil
        isDescribingObject = false
    }

    /// Crop the captured AR frame to the segmentation-mask bbox saved on the
    /// measurement result. Sensor (landscape) rect → portrait UIImage rect
    /// via the standard `.oriented(.right)` 90° CW rotation used by
    /// `capturedUIImage()`. 15% margin around the mask. This is the preferred
    /// crop because the mask is exactly what the measurement pipeline judged
    /// to be the object, so the crop is guaranteed to enclose it.
    private func croppedSnapshotFromMaskBounds(frame: ARFrame, sensorRect: CGRect) -> UIImage? {
        let sensorSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
        guard sensorSize.width > 1, sensorSize.height > 1 else { return nil }

        // 15% margin around the mask, clamped to sensor extents.
        let marginX = sensorRect.width * 0.15
        let marginY = sensorRect.height * 0.15
        let expandedSensor = sensorRect
            .insetBy(dx: -marginX, dy: -marginY)
            .intersection(CGRect(origin: .zero, size: sensorSize))
        guard expandedSensor.width > 10, expandedSensor.height > 10 else { return nil }

        // Convert sensor (landscape, top-left origin) rect to portrait UIImage
        // rect after a 90° CW rotation:
        //   portrait_x = H_sensor - y_sensor - h_sensor
        //   portrait_y = x_sensor
        //   portrait_w = h_sensor
        //   portrait_h = w_sensor
        let hSensor = sensorSize.height
        let portraitRect = CGRect(
            x: hSensor - expandedSensor.minY - expandedSensor.height,
            y: expandedSensor.minX,
            width:  expandedSensor.height,
            height: expandedSensor.width
        )

        guard let snapshot = frame.capturedUIImage(), let cg = snapshot.cgImage else {
            return nil
        }
        let portraitSize = CGSize(width: cg.width, height: cg.height)
        let clamped = portraitRect.intersection(CGRect(origin: .zero, size: portraitSize))
        guard clamped.width > 10, clamped.height > 10 else { return nil }

        guard let cropped = cg.cropping(to: clamped) else { return nil }
        return UIImage(cgImage: cropped, scale: snapshot.scale, orientation: snapshot.imageOrientation)
    }

    /// Crop the captured AR frame down to the projected 2D bbox of the
    /// measured 3D box (with 15% margin) so the VLM focuses on the object
    /// itself instead of the whole scene. ARView renders the camera with
    /// aspect-fill, so we map view-space points onto snapshot pixels using a
    /// `max-scale, centered offset` transform. Returns `nil` on any geometry
    /// or extraction failure — caller falls back to the full snapshot.
    private func croppedSnapshotForVLM(frame: ARFrame, bbox: BoundingBox3D) -> UIImage? {
        let viewport = sessionManager.arView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return nil }

        // Project 8 world-space corners → view-space 2D bbox.
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for corner in bbox.corners {
            let p = frame.camera.projectPoint(
                corner, orientation: .portrait, viewportSize: viewport
            )
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard maxX > minX, maxY > minY else { return nil }

        let w = maxX - minX, h = maxY - minY
        var viewRect = CGRect(
            x: minX - w * 0.15, y: minY - h * 0.15,
            width: w * 1.3, height: h * 1.3
        )
        viewRect = viewRect.intersection(CGRect(origin: .zero, size: viewport))
        guard viewRect.width > 10, viewRect.height > 10 else { return nil }

        guard let snapshot = frame.capturedUIImage(),
              let cg = snapshot.cgImage else { return nil }
        let snapSize = CGSize(width: cg.width, height: cg.height)

        // Aspect-fill: scale so the snapshot covers the viewport; offset is
        // the equal letterbox crop on the other axis.
        let scale = max(snapSize.width / viewport.width, snapSize.height / viewport.height)
        let offsetX = (snapSize.width  - viewport.width  * scale) / 2
        let offsetY = (snapSize.height - viewport.height * scale) / 2

        let cropRect = CGRect(
            x: viewRect.minX * scale + offsetX,
            y: viewRect.minY * scale + offsetY,
            width:  viewRect.width  * scale,
            height: viewRect.height * scale
        ).intersection(CGRect(origin: .zero, size: snapSize))
        guard cropRect.width > 10, cropRect.height > 10 else { return nil }

        guard let cropped = cg.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: snapshot.scale, orientation: snapshot.imageOrientation)
    }

    private func startObjectDescription(image: UIImage) {
        objectDescription = nil
        isDescribingObject = true
        Task { @MainActor [weak self] in
            let result = await VLMDescriptionService.shared.describe(image)
            guard let self else { return }
            self.objectDescription = result
            self.isDescribingObject = false
            // Push the description into the fixed 3D billboard. If the box
            // visualization hasn't been created yet (VLM finished before
            // Phase 6), `boxVisualization` is nil and the description will
            // instead be applied right after `showBoxVisualization`.
            self.boxVisualization?.updateDescription(result)
        }
    }

    private func captureAnnotatedImage() -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: sessionManager.arView.bounds)
        let image = renderer.image { _ in
            sessionManager.arView.drawHierarchy(in: sessionManager.arView.bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let saveMeasurement = Notification.Name("saveMeasurement")
}
