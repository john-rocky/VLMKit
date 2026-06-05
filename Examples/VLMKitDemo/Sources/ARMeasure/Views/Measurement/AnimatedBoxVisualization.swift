//
//  AnimatedBoxVisualization.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box with animation support
/// Animation flow:
/// 1. Edge trace: Bottom 4 edges draw sequentially with corner markers appearing
/// 2. Bottom plane flies from camera position to object's actual bottom
/// 3. Box grows vertically from bottom to top
/// 4. Completion pulse: Brief flash on all edges
class AnimatedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity

    // Edge entities (dual-layer: inner + outer per edge)
    private var bottomEdgeGroups: [Entity] = []    // 4 bottom dual-edge groups
    private var verticalEdgeGroups: [Entity] = []  // 4 vertical dual-edge groups
    private var topEdgeGroups: [Entity] = []       // 4 top dual-edge groups

    // Corner markers
    private var bottomCornerMarkers: [ModelEntity] = [] // 4 bottom corners
    private var topCornerMarkers: [ModelEntity] = []    // 4 top corners

    private(set) var boundingBox: BoundingBox3D

    /// Current animation progress for vertical growth (0 = bottom only, 1 = full box)
    private(set) var verticalProgress: Float = 0

    /// Current animation progress for flying (0 = at camera, 1 = at target)
    private(set) var flyProgress: Float = 0

    // Target corners (at object position)
    private var targetBottomCorners: [SIMD3<Float>] = []
    private var targetTopCorners: [SIMD3<Float>] = []

    // Start corners (at camera position)
    private var startBottomCorners: [SIMD3<Float>] = []

    // Animation state
    private var animationTimer: Timer?
    private var animationStartTime: Date?
    private var currentAnimationDuration: TimeInterval = 0.4

    // MARK: - Constants

    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInner
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuter
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadius
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarker
    private let pulseColor: UIColor = PMTheme.uiPulseColor

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        self.entity = Entity()
        computeTargetCorners()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Public Methods

    /// Setup the bottom plane at camera position, ready for edge trace then fly
    func setupAtCameraPosition(cameraTransform: simd_float4x4, distanceFromCamera: Float = 0.5, rectSize: Float = 0.3) {
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )

        let startCenter = cameraPosition + cameraForward * distanceFromCamera
        let targetCentroid = targetBottomCorners.reduce(SIMD3<Float>(0, 0, 0), +) / Float(targetBottomCorners.count)
        let targetRadius = targetBottomCorners.map { simd_length($0 - targetCentroid) }.reduce(0, +) / Float(targetBottomCorners.count)
        let desiredRadius = rectSize / 2 * sqrt(2)
        let scale = targetRadius > 0.001 ? desiredRadius / targetRadius : 1.0

        startBottomCorners = targetBottomCorners.map { corner in
            let offset = corner - targetCentroid
            let scaledOffset = offset * scale
            return startCenter + scaledOffset
        }

        flyProgress = 0
        verticalProgress = 0
        createVisualization()

        // Initially all edges hidden - edge trace will reveal bottom edges
        for group in bottomEdgeGroups { group.isEnabled = false }
        for group in verticalEdgeGroups { group.isEnabled = false }
        for group in topEdgeGroups { group.isEnabled = false }
        for marker in bottomCornerMarkers { marker.isEnabled = false }
        for marker in topCornerMarkers { marker.isEnabled = false }
    }

    /// Animate edge trace: bottom 4 edges draw sequentially, corner markers appear
    func animateEdgeTrace(duration: TimeInterval = 0.5, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        currentAnimationDuration = duration
        animationStartTime = Date()
        let perEdgeDuration = duration / 4.0

        // Show first corner marker immediately
        if !bottomCornerMarkers.isEmpty {
            bottomCornerMarkers[0].isEnabled = true
            bottomCornerMarkers[0].scale = SIMD3<Float>(repeating: 0.01)
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let overallProgress = min(elapsed / duration, 1.0)

            // Determine which edge is being traced (0-3)
            let currentEdgeIndex = min(Int(overallProgress * 4.0), 3)
            let edgeLocalProgress = Float((overallProgress * 4.0) - Double(currentEdgeIndex))

            // Enable and scale edges up to current
            for i in 0...currentEdgeIndex {
                if i < self.bottomEdgeGroups.count {
                    self.bottomEdgeGroups[i].isEnabled = true
                    if i < currentEdgeIndex {
                        // Fully traced edges
                        self.updateDualEdgeScale(self.bottomEdgeGroups[i], scale: 1.0)
                    } else {
                        // Currently tracing edge
                        self.updateDualEdgeScale(self.bottomEdgeGroups[i], scale: edgeLocalProgress)
                    }
                }
            }

            // Corner markers appear at each traced vertex (scale animation)
            for i in 0..<min(currentEdgeIndex + 1, self.bottomCornerMarkers.count) {
                self.bottomCornerMarkers[i].isEnabled = true
                self.bottomCornerMarkers[i].scale = SIMD3<Float>(repeating: 1.0)
            }

            // Show the next corner marker with scale-up during current edge trace
            let nextCornerIndex = currentEdgeIndex + 1
            if nextCornerIndex < self.bottomCornerMarkers.count {
                self.bottomCornerMarkers[nextCornerIndex].isEnabled = true
                let eased = 1.0 - pow(1.0 - edgeLocalProgress, 2)
                self.bottomCornerMarkers[nextCornerIndex].scale = SIMD3<Float>(repeating: eased)
            }

            if overallProgress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Ensure all bottom edges and markers fully visible
                for group in self.bottomEdgeGroups {
                    group.isEnabled = true
                    self.updateDualEdgeScale(group, scale: 1.0)
                }
                for marker in self.bottomCornerMarkers {
                    marker.isEnabled = true
                    marker.scale = SIMD3<Float>(repeating: 1.0)
                }

                completion?()
            }
        }
    }

    /// Animate the bottom plane flying from camera position to object bottom
    func animateFlyToBottom(duration: TimeInterval = 0.4, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        currentAnimationDuration = duration
        animationStartTime = Date()
        flyProgress = 0

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = Float(min(elapsed / self.currentAnimationDuration, 1.0))
            let easedProgress = 1.0 - pow(1.0 - progress, 3)

            self.flyProgress = easedProgress
            self.updateBottomEdgesForFly()
            self.updateBottomCornerMarkersForFly()

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.flyProgress = 1.0
                self.updateBottomEdgesForFly()
                self.updateBottomCornerMarkersForFly()
                completion?()
            }
        }
    }

    /// Animate the box growing vertically from bottom to top
    func animateGrowVertical(duration: TimeInterval = 0.4, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        currentAnimationDuration = duration
        animationStartTime = Date()
        verticalProgress = 0

        for group in verticalEdgeGroups {
            group.isEnabled = true
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = Float(min(elapsed / self.currentAnimationDuration, 1.0))
            let easedProgress = 1.0 - pow(1.0 - progress, 3)

            self.verticalProgress = easedProgress
            self.updateVerticalEdges()

            // Show top edges and corners when nearly complete
            if easedProgress > 0.85 {
                for group in self.topEdgeGroups {
                    group.isEnabled = true
                }
                self.updateTopEdges()

                // Show top corner markers with scale-up
                let topScale = (easedProgress - 0.85) / 0.15
                for marker in self.topCornerMarkers {
                    marker.isEnabled = true
                    marker.scale = SIMD3<Float>(repeating: min(topScale, 1.0))
                }
            }

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.verticalProgress = 1.0
                self.updateVerticalEdges()
                self.updateTopEdges()

                for marker in self.topCornerMarkers {
                    marker.isEnabled = true
                    marker.scale = SIMD3<Float>(repeating: 1.0)
                }

                completion?()
            }
        }
    }

    /// Completion pulse: briefly brighten all edges then fade back
    func animateCompletionPulse(duration: TimeInterval = 0.3, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()

        animationStartTime = Date()

        // Immediately set all edges to pulse color
        let pulseMaterial = UnlitMaterial(color: pulseColor)
        setAllInnerEdgeMaterial(pulseMaterial)

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] timer in
            guard let self = self, let startTime = self.animationStartTime else {
                timer.invalidate()
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / duration, 1.0)

            // First 0.1s: hold bright. After: fade back to normal cyan
            if progress > 0.33 {
                let fadeProgress = Float((progress - 0.33) / 0.67)
                let r = Float(self.pulseColor.cgColor.components?[0] ?? 0.4)
                let g = Float(self.pulseColor.cgColor.components?[1] ?? 0.95)
                let b = Float(self.pulseColor.cgColor.components?[2] ?? 1.0)
                let tr = Float(self.innerEdgeColor.cgColor.components?[0] ?? 0)
                let tg = Float(self.innerEdgeColor.cgColor.components?[1] ?? 0.85)
                let tb = Float(self.innerEdgeColor.cgColor.components?[2] ?? 1.0)

                let cr = r + (tr - r) * fadeProgress
                let cg = g + (tg - g) * fadeProgress
                let cb = b + (tb - b) * fadeProgress

                let fadedColor = UIColor(red: CGFloat(cr), green: CGFloat(cg), blue: CGFloat(cb), alpha: 1.0)
                let fadedMaterial = UnlitMaterial(color: fadedColor)
                self.setAllInnerEdgeMaterial(fadedMaterial)
            }

            if progress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil

                // Reset to normal cyan
                let normalMaterial = UnlitMaterial(color: self.innerEdgeColor)
                self.setAllInnerEdgeMaterial(normalMaterial)

                completion?()
            }
        }
    }

    // MARK: - Private Methods - Corner Computation

    private func computeTargetCorners() {
        let corners = boundingBox.corners
        let sortedByY = corners.enumerated().sorted { $0.element.y < $1.element.y }
        let bottomIndices = sortedByY.prefix(4).map { $0.offset }
        let topIndices = sortedByY.suffix(4).map { $0.offset }

        targetBottomCorners = sortCornersClockwise(bottomIndices.map { corners[$0] })
        targetTopCorners = sortCornersClockwise(topIndices.map { corners[$0] })
    }

    private func sortCornersClockwise(_ corners: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard corners.count == 4 else { return corners }
        let centroid = corners.reduce(SIMD3<Float>(0, 0, 0), +) / Float(corners.count)
        return corners.sorted { a, b in
            let angleA = atan2(a.z - centroid.z, a.x - centroid.x)
            let angleB = atan2(b.z - centroid.z, b.x - centroid.x)
            return angleA < angleB
        }
    }

    // MARK: - Private Methods - Creation

    private func createVisualization() {
        for child in entity.children {
            child.removeFromParent()
        }
        bottomEdgeGroups.removeAll()
        verticalEdgeGroups.removeAll()
        topEdgeGroups.removeAll()
        bottomCornerMarkers.removeAll()
        topCornerMarkers.removeAll()

        createBottomEdges()
        createVerticalEdges()
        createTopEdges()
        createBottomCornerMarkers()
        createTopCornerMarkers()
    }

    private func createBottomEdges() {
        let corners = currentBottomCorners()
        for i in 0..<4 {
            let start = corners[i]
            let end = corners[(i + 1) % 4]
            let group = createDualEdgeEntity(from: start, to: end, name: "anim_bottom_\(i)")
            entity.addChild(group)
            bottomEdgeGroups.append(group)
        }
    }

    private func createVerticalEdges() {
        for i in 0..<4 {
            let bottomCorner = targetBottomCorners[i]
            let group = createDualEdgeEntity(from: bottomCorner, to: bottomCorner + SIMD3<Float>(0, 0.001, 0), name: "anim_vert_\(i)")
            group.isEnabled = false
            entity.addChild(group)
            verticalEdgeGroups.append(group)
        }
    }

    private func createTopEdges() {
        for i in 0..<4 {
            let start = targetTopCorners[i]
            let end = targetTopCorners[(i + 1) % 4]
            let group = createDualEdgeEntity(from: start, to: end, name: "anim_top_\(i)")
            group.isEnabled = false
            entity.addChild(group)
            topEdgeGroups.append(group)
        }
    }

    private func createBottomCornerMarkers() {
        let corners = currentBottomCorners()
        for (i, corner) in corners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "anim_corner_bottom_\(i)"
            sphere.position = corner
            sphere.isEnabled = false
            entity.addChild(sphere)
            bottomCornerMarkers.append(sphere)
        }
    }

    private func createTopCornerMarkers() {
        for (i, corner) in targetTopCorners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "anim_corner_top_\(i)"
            sphere.position = corner
            sphere.isEnabled = false
            entity.addChild(sphere)
            topCornerMarkers.append(sphere)
        }
    }

    // Cached unit-length edge meshes (created once, scaled via transform)
    private static let unitOuterEdgeMesh = MeshResource.generateBox(size: [1, 1, 1])
    private static let unitInnerEdgeMesh = MeshResource.generateBox(size: [1, 1, 1])

    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, name: String) -> Entity {
        let parent = Entity()
        parent.name = name

        let direction = end - start
        let length = max(simd_length(direction), 0.001)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow (unit mesh scaled to actual size)
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let outerEntity = ModelEntity(mesh: Self.unitOuterEdgeMesh, materials: [outerMaterial])
        outerEntity.name = "\(name)_outer"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation
        outerEntity.scale = SIMD3<Float>(outerEdgeRadius * 2, outerEdgeRadius * 2, length)

        // Inner bright (unit mesh scaled to actual size)
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: Self.unitInnerEdgeMesh, materials: [innerMaterial])
        innerEntity.name = "\(name)_inner"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation
        innerEntity.scale = SIMD3<Float>(innerEdgeRadius * 2, innerEdgeRadius * 2, length)

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    // MARK: - Private Methods - Updates

    private func currentBottomCorners() -> [SIMD3<Float>] {
        guard startBottomCorners.count == 4, targetBottomCorners.count == 4 else {
            return targetBottomCorners
        }
        return (0..<4).map { i in
            simd_mix(startBottomCorners[i], targetBottomCorners[i], SIMD3<Float>(repeating: flyProgress))
        }
    }

    private func updateBottomEdgesForFly() {
        let corners = currentBottomCorners()
        for i in 0..<4 {
            guard i < bottomEdgeGroups.count else { continue }
            let start = corners[i]
            let end = corners[(i + 1) % 4]
            updateDualEdgeEntity(bottomEdgeGroups[i], from: start, to: end)
        }
    }

    private func updateBottomCornerMarkersForFly() {
        let corners = currentBottomCorners()
        for (i, corner) in corners.enumerated() {
            guard i < bottomCornerMarkers.count else { continue }
            bottomCornerMarkers[i].position = corner
        }
    }

    private func updateVerticalEdges() {
        for i in 0..<4 {
            guard i < verticalEdgeGroups.count else { continue }
            let bottomCorner = targetBottomCorners[i]
            let topCorner = targetTopCorners[i]
            let currentTop = simd_mix(bottomCorner, topCorner, SIMD3<Float>(repeating: verticalProgress))
            updateDualEdgeEntity(verticalEdgeGroups[i], from: bottomCorner, to: currentTop)
        }
    }

    private func updateTopEdges() {
        for i in 0..<4 {
            guard i < topEdgeGroups.count else { continue }
            let startBottom = targetBottomCorners[i]
            let startTop = targetTopCorners[i]
            let endBottom = targetBottomCorners[(i + 1) % 4]
            let endTop = targetTopCorners[(i + 1) % 4]

            let currentStart = simd_mix(startBottom, startTop, SIMD3<Float>(repeating: verticalProgress))
            let currentEnd = simd_mix(endBottom, endTop, SIMD3<Float>(repeating: verticalProgress))
            updateDualEdgeEntity(topEdgeGroups[i], from: currentStart, to: currentEnd)
        }
    }

    private func updateDualEdgeEntity(_ group: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let direction = end - start
        let length = max(simd_length(direction), 0.001)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        for child in group.children {
            guard let modelEntity = child as? ModelEntity else { continue }
            modelEntity.position = midpoint
            modelEntity.orientation = orientation
            if child.name.contains("outer") {
                modelEntity.scale = SIMD3<Float>(outerEdgeRadius * 2, outerEdgeRadius * 2, length)
            } else {
                modelEntity.scale = SIMD3<Float>(innerEdgeRadius * 2, innerEdgeRadius * 2, length)
            }
        }
    }

    /// Scale a dual-edge group (for edge trace animation - simulate drawing)
    private func updateDualEdgeScale(_ group: Entity, scale: Float) {
        // Scale the group along Z (length axis) to simulate edge drawing
        group.scale = SIMD3<Float>(1.0, 1.0, max(scale, 0.01))
    }

    /// Set all inner edges to a specific material (for pulse effect)
    private func setAllInnerEdgeMaterial(_ material: UnlitMaterial) {
        let allGroups = bottomEdgeGroups + verticalEdgeGroups + topEdgeGroups
        for group in allGroups {
            for child in group.children {
                guard let modelEntity = child as? ModelEntity,
                      child.name.contains("inner") else { continue }
                modelEntity.model?.materials = [material]
            }
        }
    }

    // MARK: - Helper Methods

    private func calculateOrientation(direction: SIMD3<Float>) -> simd_quatf {
        let len = simd_length(direction)
        guard len > 0.001 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let defaultDirection = SIMD3<Float>(0, 0, 1)
        let normalizedDirection = direction / len
        let dot = simd_dot(defaultDirection, normalizedDirection)

        if dot > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dot < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }

        let axis = simd_cross(defaultDirection, normalizedDirection)
        let axisLength = simd_length(axis)
        if axisLength > 0.001 {
            return simd_quatf(angle: acos(simd_clamp(dot, -1, 1)), axis: axis / axisLength)
        }

        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
}
