//
//  LabelLiftAnimation.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// AR lift animation: A 3D plane textured with the captured label image
/// starts exactly on top of the real label, then lifts toward the camera.
class LabelLiftAnimation {

    private(set) var entity: Entity

    private var planeEntity: ModelEntity?
    private var glowBorderEntities: [ModelEntity] = []
    private var scanEntities: [ModelEntity] = []
    private var animationTimer: Timer?

    // Animation parameters
    private var worldCorners: [SIMD3<Float>] = []
    private var surfaceNormal: SIMD3<Float> = SIMD3(0, 0, 1)
    private var labelCenter: SIMD3<Float> = .zero
    private var labelWidth: Float = 0.1
    private var labelHeight: Float = 0.1

    /// Original label center in world space
    var originalCenter: SIMD3<Float> { labelCenter }
    /// Original label surface normal in world space
    var originalSurfaceNormal: SIMD3<Float> { surfaceNormal }

    // Colors
    private let glowInnerColor = PMTheme.uiLabelBlue
    private let glowOuterColor = PMTheme.uiLabelBlueGlow

    init() {
        self.entity = Entity()
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Setup

    /// Create the label plane entity placed exactly on top of the real label
    func setup(
        labelImage: UIImage,
        worldCorners: [SIMD3<Float>]?,
        surfaceNormal: SIMD3<Float>?,
        cameraTransform: simd_float4x4? = nil,
        fallbackPosition: SIMD3<Float>? = nil
    ) {
        guard let corners = worldCorners, corners.count == 4 else {
            if let pos = fallbackPosition {
                setupFallback(labelImage: labelImage, position: pos)
            }
            return
        }

        self.worldCorners = corners
        self.surfaceNormal = surfaceNormal ?? SIMD3(0, 1, 0)

        // Calculate center and dimensions from world corners
        labelCenter = (corners[0] + corners[1] + corners[2] + corners[3]) / 4.0
        labelWidth = max(
            simd_length(corners[1] - corners[0]),
            simd_length(corners[2] - corners[3])
        )
        labelHeight = max(
            simd_length(corners[3] - corners[0]),
            simd_length(corners[2] - corners[1])
        )

        // Correct mesh aspect ratio to match the perspective-corrected texture
        let imageW = Float(labelImage.size.width)
        let imageH = Float(labelImage.size.height)
        if imageW > 0 && imageH > 0 {
            let imageAspect = imageW / imageH
            let meshAspect = labelWidth / labelHeight
            if meshAspect > imageAspect {
                labelWidth = labelHeight * imageAspect
            } else {
                labelHeight = labelWidth / imageAspect
            }
        }

        // Simple plane in XY (vertical by default), face normal +Z
        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)
        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane

        // Orient: face normal (+Z for generatePlane(width:height:)) toward camera
        var normal = simd_normalize(self.surfaceNormal)
        if let camTransform = cameraTransform {
            let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
            if simd_dot(normal, camPos - labelCenter) < 0 {
                normal = -normal
            }
        }

        // Step 1: Align face normal (+Z) to surface normal
        let q1 = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normal)

        // Step 2: Roll correction using world corners
        // After q1, local +X (plane's width axis) is at:
        let currentRight = simd_act(q1, SIMD3<Float>(1, 0, 0))

        // Roll correction — align local +X to label WIDTH direction only
        // corners: [0]=TL, [1]=TR, [2]=BR, [3]=BL
        // Width edge: TL→TR (horizontal). Height edge excluded to prevent diagonal scanlines.
        var widthDir = corners[1] - corners[0]
        widthDir = widthDir - simd_dot(widthDir, normal) * normal
        let widthLen = simd_length(widthDir)
        if widthLen > 0.001 {
            widthDir = widthDir / widthLen
            if simd_dot(widthDir, currentRight) < 0 {
                widthDir = -widthDir  // Avoid mirror flip
            }
        } else {
            widthDir = currentRight  // Degenerate fallback
        }

        let rollDot = max(-1 as Float, min(1 as Float, simd_dot(currentRight, widthDir)))
        let rollCross = simd_cross(currentRight, widthDir)
        let rollAngle = atan2(simd_dot(rollCross, normal), rollDot)
        let q2 = simd_quatf(angle: rollAngle, axis: normal)

        let orientation = q2 * q1

        // Step 3: Ensure label appears right-side-up from camera's perspective
        // The corrected image's top corresponds to screen-up (via CIPerspectiveCorrection),
        // and generatePlane maps texture top to +Y. So align +Y with screen-up on the surface.
        let finalOrientation: simd_quatf
        if let camTransform = cameraTransform {
            let sensorRight = SIMD3<Float>(camTransform.columns.0.x, camTransform.columns.0.y, camTransform.columns.0.z)
            let screenUp = -sensorRight
            var surfaceUp = screenUp - simd_dot(screenUp, normal) * normal
            let surfaceUpLen = simd_length(surfaceUp)
            if surfaceUpLen > 0.001 {
                surfaceUp /= surfaceUpLen
                let currentUp = simd_act(orientation, SIMD3<Float>(0, 1, 0))
                if simd_dot(currentUp, surfaceUp) < 0 {
                    finalOrientation = simd_quatf(angle: .pi, axis: normal) * orientation
                } else {
                    finalOrientation = orientation
                }
            } else {
                finalOrientation = orientation
            }
        } else {
            finalOrientation = orientation
        }

        entity.position = labelCenter
        entity.orientation = finalOrientation
        entity.addChild(plane)

        addGlowBorder()

        // Hide until animate() is called
        planeEntity?.scale = .zero
        for border in glowBorderEntities { border.scale = .zero }
    }

    private func setupFallback(labelImage: UIImage, position: SIMD3<Float>) {
        labelCenter = position
        labelWidth = 0.12
        labelHeight = 0.08
        surfaceNormal = SIMD3(0, 0, 1)

        let mesh = MeshResource.generatePlane(width: labelWidth, height: labelHeight)
        var material = UnlitMaterial()
        if let cgImage = labelImage.cgImage,
           let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }

        let plane = ModelEntity(mesh: mesh, materials: [material])
        planeEntity = plane
        entity.position = position
        entity.addChild(plane)
        addGlowBorder()

        // Hide until animate() is called
        planeEntity?.scale = .zero
        for border in glowBorderEntities { border.scale = .zero }
    }

    private func addGlowBorder() {
        // Black drop shadow behind the label (two layers for soft falloff)
        let layers: [(margin: Float, zOffset: Float, alpha: CGFloat)] = [
            (0.002, -0.0004, 0.15),  // tight shadow
            (0.005, -0.0008, 0.06),  // soft outer shadow
        ]

        for layer in layers {
            let mesh = MeshResource.generateBox(size: SIMD3(
                labelWidth + layer.margin * 2,
                labelHeight + layer.margin * 2,
                0.0002
            ))
            var material = UnlitMaterial()
            material.color = .init(tint: glowInnerColor.withAlphaComponent(layer.alpha))
            material.blending = .transparent(opacity: .init(floatLiteral: Float(layer.alpha)))
            let shadowEntity = ModelEntity(mesh: mesh, materials: [material])
            shadowEntity.position = SIMD3(0, 0, layer.zOffset)  // behind the label
            entity.addChild(shadowEntity)
            glowBorderEntities.append(shadowEntity)
        }
    }

    // MARK: - Visibility

    /// Hide or show the 3D entity (used for seamless 3D→2D handoff)
    func setVisible(_ visible: Bool) {
        entity.isEnabled = visible
    }

    // MARK: - Animation

    /// Animate: scan (0.5s) → reveal at surface + fly to camera (2.0s)
    func animate(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        // Hide label, show only scanline on real label position
        planeEntity?.scale = .zero
        for border in glowBorderEntities { border.scale = .zero }

        // Create scanline bar
        var scanMaterial = UnlitMaterial()
        scanMaterial.color = .init(tint: glowInnerColor.withAlphaComponent(0.5))
        scanMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        let barHeight: Float = 0.002
        let scanMesh = MeshResource.generateBox(size: SIMD3(labelWidth * 1.05, barHeight, 0.0001))
        let scanLineEntity = ModelEntity(mesh: scanMesh, materials: [scanMaterial])
        let hh = labelHeight / 2
        scanLineEntity.position = SIMD3(0, hh, 0.001)
        entity.addChild(scanLineEntity)
        scanEntities.append(scanLineEntity)

        let scanDuration: Double = 0.5
        let startTime = Date()

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)

            if elapsed < scanDuration {
                // Phase 1: Scanline sweeps top → bottom
                let t = Float(elapsed / scanDuration)
                scanLineEntity.position.y = hh - t * self.labelHeight
            } else {
                // Phase 2: Remove scanline, start combined reveal + lift
                timer.invalidate()
                self.animationTimer = nil
                if !self.scanEntities.isEmpty {
                    for e in self.scanEntities { e.removeFromParent() }
                    self.scanEntities.removeAll()
                }
                self.startRevealAndLift(cameraTransform: cameraTransform, completion: completion)
            }
        }
    }

    /// Reveal label at surface position, then fly to camera
    private func startRevealAndLift(cameraTransform: simd_float4x4, completion: @escaping () -> Void) {
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Camera forward axis
        let camForward = -simd_normalize(SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        ))

        // Compute scale so label fills ~85% of screen
        let vertFOV: Float = 60.0 * .pi / 180.0
        let screenAspect: Float = 9.0 / 19.5
        let fillFraction: Float = 0.85
        let placeDist: Float = 0.30

        let visibleH = 2.0 * placeDist * tan(vertFOV / 2.0)
        let visibleW = visibleH * screenAspect
        let scaleForH = fillFraction * visibleH / labelHeight
        let scaleForW = fillFraction * visibleW / labelWidth
        let finalScale = min(scaleForH, scaleForW)

        let finalPosition = cameraPosition + camForward * placeDist

        // Target orientation: face toward camera
        let facingDir = simd_normalize(cameraPosition - finalPosition)
        let tq1 = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: facingDir)

        let currentUp = simd_act(tq1, SIMD3<Float>(0, 1, 0))
        let sensorRight = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
        let screenUp = -sensorRight
        var desiredUp = screenUp - simd_dot(screenUp, facingDir) * facingDir
        if simd_length(desiredUp) < 0.001 {
            desiredUp = simd_normalize(simd_cross(facingDir, sensorRight))
        } else {
            desiredUp = simd_normalize(desiredUp)
        }
        let rollDot = max(Float(-1), min(Float(1), simd_dot(currentUp, desiredUp)))
        let rollCross = simd_cross(currentUp, desiredUp)
        let rollAngle = atan2(simd_dot(rollCross, facingDir), rollDot)
        let tq2 = simd_quatf(angle: rollAngle, axis: facingDir)
        let targetOrientation = tq2 * tq1

        let startPosition = entity.position
        let startOrientation = entity.orientation

        let duration = PMTheme.labelLiftDuration
        let revealDuration: Double = 0.3  // fade-in over first 0.3s
        let startTime = Date()

        // Instantly show label at surface (reveal starts from scale 0)
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let rawT = Float(min(elapsed / duration, 1.0))

            // Reveal: scale 0 → 1 over first revealDuration
            let revealT = Float(min(elapsed / revealDuration, 1.0))
            let reveal = Self.easeOutCubic(revealT)
            self.planeEntity?.scale = SIMD3<Float>(repeating: reveal)
            for border in self.glowBorderEntities { border.scale = SIMD3<Float>(repeating: reveal) }

            if rawT >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.planeEntity?.scale = .one
                for border in self.glowBorderEntities { border.scale = .one }
                self.entity.position = finalPosition
                self.entity.orientation = targetOrientation
                self.entity.scale = SIMD3<Float>(repeating: finalScale)
                completion()
                return
            }

            // Position/rotation: easeOutQuad for smooth deceleration
            let posT = Self.easeOutQuad(rawT)
            self.entity.position = simd_mix(startPosition, finalPosition, SIMD3(repeating: posT))
            self.entity.orientation = simd_slerp(startOrientation, targetOrientation, posT)

            // Scale: linear to prevent compound rushing effect
            self.entity.scale = SIMD3<Float>(repeating: 1.0 + (finalScale - 1.0) * rawT)
        }
    }

    /// Animate the lifted label back toward its original position and shrink to zero
    func transitionToOrigin(completion: @escaping () -> Void) {
        let duration = PMTheme.labelBillboardTransitionDuration
        let startTime = Date()
        let startPosition = entity.position
        let startOrientation = entity.orientation
        let startScale = entity.scale
        let targetPosition = labelCenter + surfaceNormal * 0.06

        // Target orientation: face outward along surface normal
        let targetOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: simd_normalize(surfaceNormal))

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let rawT = Float(min(elapsed / duration, 1.0))
            let t = Self.easeOutCubic(rawT)

            self.entity.position = simd_mix(startPosition, targetPosition, SIMD3(repeating: t))
            self.entity.orientation = simd_slerp(startOrientation, targetOrientation, t)
            self.entity.scale = startScale * (1.0 - t)

            if rawT >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.entity.isEnabled = false
                completion()
            }
        }
    }

    /// Dismiss the label with fade out
    func dismiss(completion: @escaping () -> Void) {
        let duration = PMTheme.labelDismissDuration
        let startTime = Date()
        let startScale = entity.scale

        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))

            self.entity.scale = startScale * (1.0 - t)

            if t >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.entity.removeFromParent()
                completion()
            }
        }
    }

    // MARK: - Easing Functions

    private static func easeOutCubic(_ t: Float) -> Float {
        1.0 - pow(1.0 - t, 3)
    }

    private static func easeOutQuad(_ t: Float) -> Float {
        return 1.0 - (1.0 - t) * (1.0 - t)
    }

}
