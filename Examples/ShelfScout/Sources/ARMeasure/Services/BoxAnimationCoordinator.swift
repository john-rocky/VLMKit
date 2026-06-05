//
//  BoxAnimationCoordinator.swift
//  SnapMeasure
//

import Foundation
import RealityKit
import ARKit
import CoreGraphics
import simd

/// Coordinates the bounding box appearance animation between SwiftUI and RealityKit
@MainActor
class BoxAnimationCoordinator: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var phase: BoundingBoxAnimationPhase = .showingTargetBrackets
    @Published private(set) var context: BoundingBoxAnimationContext?

    // MARK: - Properties

    private var animatedVisualization: AnimatedBoxVisualization?
    private weak var arView: ARView?
    private var currentAnimationTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {}

    func configure(arView: ARView) {
        self.arView = arView
    }

    // MARK: - Animation Control

    /// Cancel the current animation
    func cancelAnimation() {
        currentAnimationTask?.cancel()
        currentAnimationTask = nil

        // Remove visualization if it exists
        animatedVisualization?.entity.removeFromParent()
        animatedVisualization = nil

        phase = .showingTargetBrackets
        context = nil
    }

    /// Reset to targeting state
    func reset() {
        cancelAnimation()
    }

    // MARK: - Projection Methods

    /// Project a 3D world position to 2D screen coordinates
    func projectToScreen(worldPosition: SIMD3<Float>, frame: ARFrame, screenSize: CGSize) -> CGPoint? {
        let camera = frame.camera

        // Get the camera's projection and view matrices
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projectionMatrix = camera.projectionMatrix(for: .portrait, viewportSize: screenSize, zNear: 0.01, zFar: 100)

        // Transform world position to camera space
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let cameraPos = viewMatrix * worldPos4

        // Project to clip space
        let clipPos = projectionMatrix * cameraPos

        // Check if behind camera
        guard clipPos.w > 0 else { return nil }

        // Convert to NDC (Normalized Device Coordinates)
        let ndcX = clipPos.x / clipPos.w
        let ndcY = clipPos.y / clipPos.w

        // Convert to screen coordinates
        // NDC is [-1, 1], screen is [0, screenSize]
        let screenX = (CGFloat(ndcX) + 1) / 2 * screenSize.width
        let screenY = (1 - CGFloat(ndcY)) / 2 * screenSize.height  // Flip Y for screen coordinates

        return CGPoint(x: screenX, y: screenY)
    }

    /// Project the bottom plane corners of a bounding box to screen coordinates
    func projectBottomPlaneCorners(of box: BoundingBox3D, frame: ARFrame, screenSize: CGSize) -> [CGPoint] {
        let corners = box.corners

        // Bottom corners are indices 0, 1, 2, 3
        let bottomCorners = [corners[0], corners[1], corners[2], corners[3]]

        var screenPoints: [CGPoint] = []

        for corner in bottomCorners {
            if let screenPoint = projectToScreen(worldPosition: corner, frame: frame, screenSize: screenSize) {
                screenPoints.append(screenPoint)
            }
        }

        return screenPoints
    }
}

// MARK: - ARSessionManager Extension

extension ARSessionManager {
    /// Project a 3D world position to 2D screen coordinates
    func projectToScreen(worldPosition: SIMD3<Float>) -> CGPoint? {
        guard let frame = currentFrame else { return nil }

        let screenSize = arView.bounds.size
        let camera = frame.camera

        // Get the camera's projection and view matrices
        let viewMatrix = camera.viewMatrix(for: .portrait)
        let projectionMatrix = camera.projectionMatrix(for: .portrait, viewportSize: screenSize, zNear: 0.01, zFar: 100)

        // Transform world position to camera space
        let worldPos4 = SIMD4<Float>(worldPosition.x, worldPosition.y, worldPosition.z, 1.0)
        let cameraPos = viewMatrix * worldPos4

        // Project to clip space
        let clipPos = projectionMatrix * cameraPos

        // Check if behind camera
        guard clipPos.w > 0 else { return nil }

        // Convert to NDC (Normalized Device Coordinates)
        let ndcX = clipPos.x / clipPos.w
        let ndcY = clipPos.y / clipPos.w

        // Convert to screen coordinates
        let screenX = (CGFloat(ndcX) + 1) / 2 * screenSize.width
        let screenY = (1 - CGFloat(ndcY)) / 2 * screenSize.height

        return CGPoint(x: screenX, y: screenY)
    }

    /// Project the bottom plane corners of a bounding box to screen coordinates
    func projectBottomPlaneCorners(of box: BoundingBox3D) -> [CGPoint] {
        let corners = box.corners

        // Bottom corners are indices 0, 1, 2, 3
        let bottomCorners = [corners[0], corners[1], corners[2], corners[3]]

        var screenPoints: [CGPoint] = []

        for corner in bottomCorners {
            if let screenPoint = projectToScreen(worldPosition: corner) {
                screenPoints.append(screenPoint)
            }
        }

        return screenPoints
    }
}
