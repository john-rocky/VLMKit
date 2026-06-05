//
//  ARSessionManager.swift
//  SnapMeasure
//

import ARKit
import RealityKit
import Combine

/// Manages the AR session lifecycle and frame handling
@MainActor
class ARSessionManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var trackingState: ARCamera.TrackingState = .notAvailable
    @Published var trackingStateMessage: String = String(localized: "Initializing...")
    @Published var isTrackingReady: Bool = false
    @Published var isTrackingError: Bool = false
    @Published var isDepthAvailable: Bool = false
    @Published var depthMode: DepthMode = .none
    var currentFrame: ARFrame?

    // MARK: - AR Components

    private(set) var arView: ARView!
    private var session: ARSession { arView.session }

    // MARK: - Callbacks

    var onFrameUpdate: ((ARFrame) -> Void)?

    /// Timestamp of last frame forwarded to onFrameUpdate (throttle to ~20fps)
    private var lastFrameTimestamp: TimeInterval = 0

    /// Latest ARFrame received from the delegate. Overwritten on every callback so
    /// older frames are released immediately rather than queued behind a busy
    /// MainActor (which would otherwise pile up ARFrames + LiDAR depth and trip
    /// jetsam during VLM model load/inference).
    private let frameSlotLock = NSLock()
    nonisolated(unsafe) private var latestFrameSlot: ARFrame?
    nonisolated(unsafe) private var hasPendingMainActorSync = false

    // MARK: - Initialization

    override init() {
        super.init()
        setupARView()
    }

    private func setupARView() {
        arView = ARView(frame: .zero)
        arView.session.delegate = self

        // Configure AR view
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [.disablePersonOcclusion, .disableDepthOfField]
    }

    // MARK: - Session Control

    func startSession() {
        guard LiDARChecker.isARKitSupported else {
            trackingStateMessage = String(localized: "ARKit is not supported on this device")
            isTrackingError = true
            isTrackingReady = false
            return
        }

        let config = ARWorldTrackingConfiguration()

        // Enable depth if available
        depthMode = LiDARChecker.depthMode
        if LiDARChecker.isSmoothedDepthAvailable {
            config.frameSemantics.insert(.smoothedSceneDepth)
            isDepthAvailable = true
        } else if LiDARChecker.isLiDARAvailable {
            config.frameSemantics.insert(.sceneDepth)
            isDepthAvailable = true
        } else if depthMode == .mlFallback {
            // ML depth provides depth without LiDAR hardware
            isDepthAvailable = true
        }

        // Enable plane detection for better tracking
        config.planeDetection = [.horizontal, .vertical]

        // Enable auto-focus for better camera quality
        config.isAutoFocusEnabled = true

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pauseSession() {
        session.pause()
    }

    func resetSession() {
        let config = session.configuration as? ARWorldTrackingConfiguration
        if let config = config {
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }
    }

    // MARK: - Raycast

    func raycast(from point: CGPoint) -> ARRaycastResult? {
        let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
        return results.first
    }

    func raycastWorldPosition(from point: CGPoint) -> SIMD3<Float>? {
        raycast(from: point)?.worldTransform.columns.3.xyz
    }

    // MARK: - Entity Management

    func addEntity(_ entity: Entity) {
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
    }

    /// Add an entity with a returned anchor for later selective removal
    @discardableResult
    func addEntityWithAnchor(_ entity: Entity) -> AnchorEntity {
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        arView.scene.addAnchor(anchor)
        return anchor
    }

    /// Remove a specific anchor from the scene
    func removeAnchor(_ anchor: AnchorEntity) {
        anchor.removeFromParent()
    }

    func removeAllEntities() {
        arView.scene.anchors.removeAll()
    }
}

// MARK: - ARSessionDelegate

extension ARSessionManager: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Atomically replace the latest frame; the previous one is released here.
        // Only schedule a MainActor hop if none is already pending — at most one
        // ARFrame is ever held by an enqueued Task, regardless of MainActor load.
        frameSlotLock.lock()
        latestFrameSlot = frame
        let shouldSchedule = !hasPendingMainActorSync
        if shouldSchedule { hasPendingMainActorSync = true }
        frameSlotLock.unlock()

        guard shouldSchedule else { return }

        Task { @MainActor in
            self.consumeLatestFrame()
        }
    }

    @MainActor
    private func consumeLatestFrame() {
        frameSlotLock.lock()
        let frame = latestFrameSlot
        hasPendingMainActorSync = false
        frameSlotLock.unlock()

        guard let frame else { return }
        self.currentFrame = frame
        self.updateTrackingState(frame.camera.trackingState)

        // Throttle onFrameUpdate to ~20fps (50ms interval)
        let timestamp = frame.timestamp
        guard timestamp - self.lastFrameTimestamp >= 0.05 else { return }
        self.lastFrameTimestamp = timestamp
        self.onFrameUpdate?(frame)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.trackingStateMessage = String(localized: "Session failed: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.trackingStateMessage = String(localized: "Session interrupted")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.resetSession()
        }
    }
}

// MARK: - Private Helpers

private extension ARSessionManager {
    func updateTrackingState(_ state: ARCamera.TrackingState) {
        guard trackingState != state else { return }
        trackingState = state

        switch state {
        case .notAvailable:
            trackingStateMessage = String(localized: "Tracking not available")
            isTrackingReady = false
            isTrackingError = true
        case .limited(let reason):
            isTrackingReady = false
            isTrackingError = false
            switch reason {
            case .initializing:
                trackingStateMessage = String(localized: "Initializing AR...")
            case .excessiveMotion:
                trackingStateMessage = String(localized: "Move device slower")
            case .insufficientFeatures:
                trackingStateMessage = String(localized: "Point at more textured surfaces")
            case .relocalizing:
                trackingStateMessage = String(localized: "Relocalizing...")
            @unknown default:
                trackingStateMessage = String(localized: "Limited tracking")
            }
        case .normal:
            trackingStateMessage = String(localized: "Ready to measure")
            isTrackingReady = true
            isTrackingError = false
        }
    }
}

// MARK: - SIMD Helpers

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
