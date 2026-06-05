//
//  BoxVisualization.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// Creates RealityKit entities for visualizing a 3D bounding box
class BoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [Entity] = []          // 12 dual-layer edge groups
    private var cornerMarkerEntities: [ModelEntity] = [] // 8 corner spheres
    private var faceHandleEntities: [Entity] = []    // 6 face handles
    private var rotationRingEntity: Entity?          // Rotation ring on top
    private var labelEntities: [Entity] = []
    private var floorDistanceEntity: Entity?         // Floor distance indicator
    private var floorDistanceLabel: Entity?

    // Single billboard label floating above the box (shows all dimensions)
    private var dimensionBillboardEntity: Entity?

    // Action icon row (below billboard)
    private var actionIconRow: Entity?

    /// Current action mode
    enum ActionMode {
        case normal
        case normalNoRefine
        case editing
        case refining
        case labelExpanded
        case labelExpandedNoRefine
    }
    private var currentActionMode: ActionMode = .normal

    // Box identifier
    private var boxId: Int = 0

    // Stored dimensions for label updates
    private var storedHeight: Float = 0
    private var storedLength: Float = 0
    private var storedWidth: Float = 0
    private var storedUnit: MeasurementUnit = .centimeters

    // Stored console data for billboard
    private var storedQualityLabel: String = ""
    private var storedPointCount: Int = 0
    private var storedLabelData: LabelData?
    /// VLMKit-generated description of the measured object. Set asynchronously
    /// via `updateDescription(_:)` once the VLM call returns. Triggers a
    /// dimension-billboard rebuild so the text appears under the dimensions.
    private var storedDescription: String?

    // Structural entity references (for in-place label expansion)
    private var billboardContainerEntity: Entity?
    private var bgEntity: ModelEntity?
    private var glowEntity: ModelEntity?
    private var accentEntity: ModelEntity?
    private var accentGlowEntity: ModelEntity?
    private var topBorderEntity: ModelEntity?
    private var bottomBorderEntity: ModelEntity?

    // Layout metrics (set during build, used for expansion)
    private var currentTotalHeight: Float = 0
    private var currentTotalWidth: Float = 0
    private var currentMaxContentWidth: Float = 0
    private var currentMaxLabelWidth: Float = 0

    // Stagger animation entities for label expansion
    private var revealEntities: [Entity] = []

    /// Whether this billboard has been expanded with label data
    private(set) var isExpandedWithLabel: Bool = false

    private(set) var boundingBox: BoundingBox3D

    /// Floor Y position (default 0)
    var floorY: Float = 0 {
        didSet {
            updateFloorDistanceIndicator()
        }
    }

    /// Whether handles are interactive (draggable)
    var isInteractive: Bool = false {
        didSet {
            if oldValue != isInteractive {
                updateInteractiveState()
            }
        }
    }

    // MARK: - Constants

    // Dual-layer edge: inner bright + outer glow
    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInner
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuter
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius

    // Corner markers
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadius
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarker

    // Handle color (white, semi-transparent for Apple-style appearance)
    private let handleColor: UIColor = UIColor(white: 1.0, alpha: 0.85)

    // Handle dimensions (capsule shape)
    private let handleLength: Float = 0.018
    private let handleRadius: Float = 0.004
    private let handleCollisionRadius: Float = 0.015

    // Dimension label styling
    private let billboardIdFontSize: CGFloat = 0.014
    private let billboardBodyFontSize: CGFloat = 0.010
    private let billboardSectionFontSize: CGFloat = 0.007
    private let dimensionLabelTextColor: UIColor = PMTheme.uiBillboardText
    private let dimensionLabelDimColor: UIColor = UIColor(white: 1.0, alpha: 0.50)
    private let dimensionLabelBackgroundColor: UIColor = PMTheme.uiBillboardBg
    private let billboardAccentColor: UIColor = PMTheme.uiBillboardAccent
    private let billboardTopBorderColor: UIColor = PMTheme.uiBillboardTopBorder

    // Rotation handle
    private let rotationArcThickness: Float = 0.001
    private let rotationArcAngle: Float = .pi / 2

    // MARK: - Initialization

    init(boundingBox: BoundingBox3D, interactive: Bool = false) {
        self.boundingBox = boundingBox
        self.isInteractive = interactive
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    func update(boundingBox: BoundingBox3D) {
        self.boundingBox = boundingBox
        updateEdgePositions()
        updateCornerMarkerPositions()
        updateFaceHandlePositions()
        updateRotationRingPosition()
        updateFloorDistanceIndicator()
        updateDimensionLabelPositions()
    }

    /// Set dimensions and create/update labels on the wireframe
    func setDimensions(height: Float, length: Float, width: Float, unit: MeasurementUnit, boxId: Int = 0,
                       qualityLabel: String = "", pointCount: Int = 0, labelData: LabelData? = nil) {
        self.boxId = boxId
        storedHeight = height
        storedLength = length
        storedWidth = width
        storedUnit = unit
        storedQualityLabel = qualityLabel
        storedPointCount = pointCount
        storedLabelData = labelData
        createDimensionLabels()
        recolorEdges(forBoxId: boxId)
    }

    /// Update dimensions when box is edited (recreates labels only if values changed)
    func updateDimensions(height: Float, length: Float, width: Float) {
        guard height != storedHeight || length != storedLength || width != storedWidth else { return }
        storedHeight = height
        storedLength = length
        storedWidth = width
        createDimensionLabels()
    }

    /// Update billboard orientation to face the camera
    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        guard let billboard = dimensionBillboardEntity else { return }

        let billboardPos = billboard.position(relativeTo: nil)
        let toCamera = cameraPosition - billboardPos
        let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

        if simd_length(toCameraHorizontal) > 0.01 {
            let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
            billboard.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    /// Show or hide the dimension billboard
    func setDimensionBillboardVisible(_ visible: Bool, forceShow: Bool = false) {
        dimensionBillboardEntity?.isEnabled = forceShow || visible
    }

    /// Update the action icon row to match the current mode
    func updateActionMode(_ mode: ActionMode) {
        currentActionMode = mode
        actionIconRow?.removeFromParent()
        actionIconRow = nil

        guard let billboard = dimensionBillboardEntity else { return }

        let actions: [ActionIconConfig]
        switch mode {
        case .normal:
            actions = ActionIconBuilder.activeNormalActions
        case .normalNoRefine:
            actions = ActionIconBuilder.activeNormalActionsNoRefine
        case .editing:
            actions = ActionIconBuilder.activeEditActions
        case .refining:
            actions = ActionIconBuilder.activeRefiningActions
        case .labelExpanded:
            actions = ActionIconBuilder.warehouseCombinedActions
        case .labelExpandedNoRefine:
            actions = ActionIconBuilder.warehouseCombinedNoRefineActions
        }

        let row = ActionIconBuilder.createActionRow(actions: actions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        billboard.addChild(row)
        actionIconRow = row
    }

    /// Check if this box is visible
    func isVisibleFromCamera(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) -> Bool {
        let toBox = boundingBox.center - cameraPosition
        let distance = simd_length(toBox)
        let toBoxNormalized = toBox / distance
        let dot = simd_dot(toBoxNormalized, cameraForward)
        return dot > 0.3
    }

    /// Get the apparent size of this box from the camera
    func apparentSizeFromCamera(cameraPosition: SIMD3<Float>) -> Float {
        let distance = simd_length(boundingBox.center - cameraPosition)
        if distance < 0.01 { return 0 }
        let boxSize = boundingBox.extents.x * boundingBox.extents.y * boundingBox.extents.z
        return boxSize / (distance * distance)
    }

    /// Identify what was hit: face handle, rotation ring, or nothing
    enum HitType {
        case faceHandle(HandleType)
        case rotationRing
        case none
    }

    /// Parse entity name to determine hit type
    static func parseHit(entityName: String) -> HitType {
        if let handleType = HandleType.from(name: entityName) {
            return .faceHandle(handleType)
        }
        if entityName == "rotation_ring" {
            return .rotationRing
        }
        return .none
    }

    /// Highlight a handle
    func highlightHandle(_ handleType: HandleType) {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        guard let index = handleTypes.firstIndex(of: handleType),
              index < faceHandleEntities.count else { return }

        faceHandleEntities[index].scale = SIMD3<Float>(repeating: 1.3)
    }

    /// Highlight rotation handle
    func highlightRotationHandle() {
        rotationRingEntity?.scale = SIMD3<Float>(repeating: 1.3)
    }

    /// Remove all handle highlights
    func unhighlightAllHandles() {
        for handle in faceHandleEntities {
            handle.scale = SIMD3<Float>(repeating: 1.0)
        }
        rotationRingEntity?.scale = SIMD3<Float>(repeating: 1.0)
    }

    /// Recolor edge and corner entities (no-op, kept for API compatibility)
    func recolorEdges(forBoxId id: Int) {
        // No recoloring needed — all boxes use the default color scheme
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createCornerMarkers()
        createFaceHandles()
        createRotationRing()
        createFloorDistanceIndicator()
        updateInteractiveState()
    }

    private func updateInteractiveState() {
        for handle in faceHandleEntities {
            handle.isEnabled = isInteractive
        }
        rotationRingEntity?.isEnabled = isInteractive
    }

    private func removeVisualization() {
        for child in entity.children {
            child.removeFromParent()
        }
        edgeEntities.removeAll()
        cornerMarkerEntities.removeAll()
        faceHandleEntities.removeAll()
        rotationRingEntity = nil
        floorDistanceEntity = nil
        floorDistanceLabel = nil
        labelEntities.removeAll()
        dimensionBillboardEntity = nil
        actionIconRow = nil
        billboardContainerEntity = nil
        bgEntity = nil
        glowEntity = nil
        accentEntity = nil
        accentGlowEntity = nil
        topBorderEntity = nil
        bottomBorderEntity = nil
        revealEntities.removeAll()
        isExpandedWithLabel = false
    }

    // MARK: - Dual-Layer Edge Creation

    private func createEdges() {
        let edges = boundingBox.edges

        for (index, (start, end)) in edges.enumerated() {
            let edgeGroup = createDualEdgeEntity(from: start, to: end, index: index)
            entity.addChild(edgeGroup)
            edgeEntities.append(edgeGroup)
        }
    }

    private func updateEdgePositions() {
        let edges = boundingBox.edges

        guard edgeEntities.count == edges.count else {
            for edge in edgeEntities { edge.removeFromParent() }
            edgeEntities.removeAll()
            createEdges()
            return
        }

        for (index, (start, end)) in edges.enumerated() {
            updateDualEdgeEntity(edgeEntities[index], from: start, to: end)
        }
    }

    // Cached unit-length edge meshes (created once, scaled via transform)
    private static let unitOuterEdgeMesh = MeshResource.generateBox(size: [1, 1, 1])
    private static let unitInnerEdgeMesh = MeshResource.generateBox(size: [1, 1, 1])

    /// Create a dual-layer edge: inner bright line + outer glow
    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> Entity {
        let parent = Entity()
        parent.name = "edge_\(index)"

        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow layer (unit mesh scaled to actual size)
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let outerEntity = ModelEntity(mesh: Self.unitOuterEdgeMesh, materials: [outerMaterial])
        outerEntity.name = "edge_outer_\(index)"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation
        outerEntity.scale = SIMD3<Float>(outerEdgeRadius * 2, outerEdgeRadius * 2, length)

        // Inner bright layer (unit mesh scaled to actual size)
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: Self.unitInnerEdgeMesh, materials: [innerMaterial])
        innerEntity.name = "edge_inner_\(index)"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation
        innerEntity.scale = SIMD3<Float>(innerEdgeRadius * 2, innerEdgeRadius * 2, length)

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    private func updateDualEdgeEntity(_ edgeGroup: Entity, from start: SIMD3<Float>, to end: SIMD3<Float>) {
        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        let children = edgeGroup.children.compactMap { $0 as? ModelEntity }
        for child in children {
            child.position = midpoint
            child.orientation = orientation
            if child.name.contains("outer") {
                child.scale = SIMD3<Float>(outerEdgeRadius * 2, outerEdgeRadius * 2, length)
            } else {
                child.scale = SIMD3<Float>(innerEdgeRadius * 2, innerEdgeRadius * 2, length)
            }
        }
    }

    // MARK: - Corner Markers

    private func createCornerMarkers() {
        let corners = boundingBox.corners
        for (index, corner) in corners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "corner_\(index)"
            sphere.position = corner
            entity.addChild(sphere)
            cornerMarkerEntities.append(sphere)
        }
    }

    private func updateCornerMarkerPositions() {
        let corners = boundingBox.corners
        guard cornerMarkerEntities.count == corners.count else {
            for m in cornerMarkerEntities { m.removeFromParent() }
            cornerMarkerEntities.removeAll()
            createCornerMarkers()
            return
        }
        for (index, corner) in corners.enumerated() {
            cornerMarkerEntities[index].position = corner
        }
    }

    // MARK: - Face Handle Creation

    private func createFaceHandles() {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        for handleType in handleTypes {
            let handleEntity = createFaceHandleEntity(for: handleType)
            entity.addChild(handleEntity)
            faceHandleEntities.append(handleEntity)
        }
    }

    private func createFaceHandleEntity(for handleType: HandleType) -> Entity {
        let parentEntity = Entity()
        parentEntity.name = handleType.entityName

        let material = UnlitMaterial(color: handleColor)
        let capsuleMesh = MeshResource.generateBox(
            size: [handleRadius * 2, handleRadius * 2, handleLength],
            cornerRadius: handleRadius
        )
        let capsuleEntity = ModelEntity(mesh: capsuleMesh, materials: [material])
        parentEntity.addChild(capsuleEntity)

        let collisionShape = ShapeResource.generateCapsule(height: handleLength, radius: handleCollisionRadius)
        parentEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        let localPos = handleType.localPosition(extents: boundingBox.extents)
        parentEntity.position = boundingBox.localToWorld(localPos)
        parentEntity.orientation = calculateHandleOrientation(for: handleType)
        parentEntity.isEnabled = isInteractive

        return parentEntity
    }

    private func updateFaceHandlePositions() {
        let handleTypes: [HandleType] = [
            .faceNegX, .facePosX,
            .faceNegY, .facePosY,
            .faceNegZ, .facePosZ
        ]

        for (index, handleType) in handleTypes.enumerated() {
            guard index < faceHandleEntities.count else { continue }
            let localPos = handleType.localPosition(extents: boundingBox.extents)
            faceHandleEntities[index].position = boundingBox.localToWorld(localPos)
            faceHandleEntities[index].orientation = calculateHandleOrientation(for: handleType)
        }
    }

    private func calculateHandleOrientation(for handleType: HandleType) -> simd_quatf {
        let axes = boundingBox.localAxes
        let targetDirection: SIMD3<Float>
        switch handleType {
        case .faceNegX, .facePosX:
            targetDirection = axes.z
        case .faceNegZ, .facePosZ:
            targetDirection = axes.x
        case .faceNegY, .facePosY:
            targetDirection = axes.x
        default:
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return calculateOrientation(direction: targetDirection)
    }

    // MARK: - Rotation Handle Creation

    /// Cached torus arc mesh generated at unit radius (1.0), scaled to actual size
    private var cachedTorusMesh: MeshResource?
    private let torusUnitRadius: Float = 1.0

    private func createRotationRing() {
        let handleEntity = Entity()
        handleEntity.name = "rotation_ring"

        let material = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.6))
        let placeholderRadius: Float = 0.03

        if cachedTorusMesh == nil {
            cachedTorusMesh = createTorusArcMesh(
                majorRadius: torusUnitRadius,
                minorRadius: rotationArcThickness,
                startAngle: 0,
                arcAngle: rotationArcAngle
            )
        }

        if let torusMesh = cachedTorusMesh {
            let torusEntity = ModelEntity(mesh: torusMesh, materials: [material])
            torusEntity.name = "rotation_arc"
            let meshScale = placeholderRadius / torusUnitRadius
            torusEntity.scale = SIMD3<Float>(repeating: meshScale)
            handleEntity.addChild(torusEntity)
        }

        let arrowSize: Float = 0.004
        let arrowMesh = MeshResource.generateBox(
            size: [arrowSize, arrowSize * 0.5, arrowSize],
            cornerRadius: arrowSize * 0.2
        )
        let arrowHead = ModelEntity(mesh: arrowMesh, materials: [material])
        arrowHead.name = "rotation_arrow"
        arrowHead.position = SIMD3<Float>(0, 0, placeholderRadius)
        arrowHead.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        handleEntity.addChild(arrowHead)

        let collisionShape = ShapeResource.generateBox(
            size: [placeholderRadius * 2.5, 0.02, placeholderRadius * 2.5]
        )
        handleEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        updateRotationRingTransform(handleEntity)
        handleEntity.isEnabled = isInteractive

        entity.addChild(handleEntity)
        rotationRingEntity = handleEntity
    }

    private func createTorusArcMesh(
        majorRadius: Float,
        minorRadius: Float,
        startAngle: Float,
        arcAngle: Float
    ) -> MeshResource? {
        let majorSegments = 32
        let minorSegments = 12

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for i in 0...majorSegments {
            let majorAngle = startAngle + arcAngle * Float(i) / Float(majorSegments)
            let majorCos = cos(majorAngle)
            let majorSin = sin(majorAngle)
            let centerX = majorCos * majorRadius
            let centerZ = majorSin * majorRadius

            for j in 0...minorSegments {
                let minorAngle = 2.0 * .pi * Float(j) / Float(minorSegments)
                let minorCos = cos(minorAngle)
                let minorSin = sin(minorAngle)

                let x = centerX + majorCos * minorRadius * minorCos
                let y = minorRadius * minorSin
                let z = centerZ + majorSin * minorRadius * minorCos

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(SIMD3<Float>(majorCos * minorCos, minorSin, majorSin * minorCos))
                uvs.append(SIMD2<Float>(Float(i) / Float(majorSegments), Float(j) / Float(minorSegments)))
            }
        }

        let minorCount = minorSegments + 1
        for i in 0..<majorSegments {
            for j in 0..<minorSegments {
                let current = UInt32(i * minorCount + j)
                let next = UInt32((i + 1) * minorCount + j)
                indices.append(contentsOf: [current, next, current + 1, current + 1, next, next + 1])
            }
        }

        var descriptor = MeshDescriptor(name: "torusArc")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [descriptor])
    }

    private func updateRotationRingPosition() {
        guard let ringEntity = rotationRingEntity else { return }
        updateRotationRingTransform(ringEntity)
    }

    private func updateRotationRingTransform(_ ringEntity: Entity) {
        let arcRadius = min(boundingBox.extents.x, boundingBox.extents.z) * 0.4

        let bottomY = -boundingBox.extents.y
        let cornerX = boundingBox.extents.x
        let cornerZ = boundingBox.extents.z
        let localPos = SIMD3<Float>(cornerX, bottomY, cornerZ)
        ringEntity.position = boundingBox.localToWorld(localPos)
        ringEntity.orientation = boundingBox.rotation

        // Scale cached torus mesh instead of regenerating
        if let arcEntity = ringEntity.children.first(where: { $0.name == "rotation_arc" }) as? ModelEntity {
            let meshScale = arcRadius / torusUnitRadius
            arcEntity.scale = SIMD3<Float>(repeating: meshScale)
        }

        if let arrowEntity = ringEntity.children.first(where: { $0.name == "rotation_arrow" }) as? ModelEntity {
            arrowEntity.position = SIMD3<Float>(0, 0, arcRadius)
        }

        let collisionShape = ShapeResource.generateBox(
            size: [arcRadius * 2.5, 0.02, arcRadius * 2.5]
        )
        ringEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
    }

    // MARK: - Floor Distance Indicator

    private func createFloorDistanceIndicator() {
        // Floor distance indicator disabled — not useful for end users
    }

    private func updateFloorDistanceIndicator() {
        guard let indicatorEntity = floorDistanceEntity else { return }

        for child in indicatorEntity.children {
            child.removeFromParent()
        }

        let bottomLocalY = -boundingBox.extents.y
        let bottomCenter = boundingBox.localToWorld(SIMD3<Float>(0, bottomLocalY, 0))
        let distanceToFloor = bottomCenter.y - floorY

        guard distanceToFloor > 0.001 else {
            indicatorEntity.isEnabled = false
            return
        }
        indicatorEntity.isEnabled = true

        let floorPoint = SIMD3<Float>(bottomCenter.x, floorY, bottomCenter.z)

        // Dashed line
        let dashLength: Float = 0.01
        let gapLength: Float = 0.008
        let segmentLength = dashLength + gapLength
        let numSegments = Int(distanceToFloor / segmentLength)

        let dashColor = PMTheme.uiCyan.withAlphaComponent(0.5)

        for i in 0..<max(1, numSegments) {
            let segmentY = floorY + Float(i) * segmentLength + dashLength / 2
            if segmentY > bottomCenter.y { break }

            let dashMesh = MeshResource.generateBox(size: [0.001, dashLength, 0.001])
            let material = UnlitMaterial(color: dashColor)
            let dashEntity = ModelEntity(mesh: dashMesh, materials: [material])
            dashEntity.position = SIMD3<Float>(bottomCenter.x, segmentY, bottomCenter.z)
            indicatorEntity.addChild(dashEntity)
        }

        // Distance label
        let labelPosition = SIMD3<Float>(bottomCenter.x + 0.02, (bottomCenter.y + floorY) / 2, bottomCenter.z)
        let distanceCm = distanceToFloor * 100
        let labelText = String(format: "%.1f cm", distanceCm)

        let textMesh = MeshResource.generateText(
            labelText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: 0.012, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        let textMaterial = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.8))
        let labelEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        labelEntity.position = labelPosition
        indicatorEntity.addChild(labelEntity)

        // Floor marker
        let markerMesh = MeshResource.generateBox(size: [0.02, 0.001, 0.02])
        let markerMaterial = UnlitMaterial(color: PMTheme.uiCyan.withAlphaComponent(0.3))
        let markerEntity = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
        markerEntity.position = floorPoint
        indicatorEntity.addChild(markerEntity)
    }

    // MARK: - Helper Methods

    private func calculateOrientation(direction: SIMD3<Float>) -> simd_quatf {
        let defaultDirection = SIMD3<Float>(0, 0, 1)
        let normalizedDirection = simd_normalize(direction)
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

    // MARK: - Dimension Billboard (floating above box)

    private func createDimensionLabels() {
        dimensionBillboardEntity?.removeFromParent()
        actionIconRow = nil

        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        dimensionBillboardEntity = createDimensionBillboard(at: billboardPos)
        entity.addChild(dimensionBillboardEntity!)

        updateActionMode(currentActionMode)
        dimensionBillboardEntity?.isEnabled = true
    }

    private func updateDimensionLabelPositions() {
        guard storedHeight > 0 else { return }
        if let billboard = dimensionBillboardEntity {
            billboard.position = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        }
    }

    // Labels to emphasize as check items (rendered with accent color + bold weight)
    private static let highlightLabels: Set<String> = ["CTN ID", "BARCODE", "DEST", "SIZE"]

    private static func isHighlightLabel(_ label: String) -> Bool {
        highlightLabels.contains(label) || label.hasPrefix("BARCODE ")
    }

    /// Greedy word-wrap on whitespace for a single paragraph using the supplied
    /// font's actual glyph widths. Long words that don't fit on their own are
    /// allowed to overflow (one per line) rather than being broken mid-word.
    private static func wordWrap(_ text: String, font: UIFont, maxWidth: CGFloat) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            let width = (candidate as NSString).size(withAttributes: attributes).width
            if width <= maxWidth || current.isEmpty {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func createDimensionBillboard(at position: SIMD3<Float>, animateLabelSection: Bool = false) -> Entity {
        let containerEntity = Entity()
        containerEntity.position = position
        self.billboardContainerEntity = containerEntity

        // Layout constants
        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let labelValueGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        // Cyber colors
        let labelColor = billboardAccentColor.withAlphaComponent(0.55)
        let valueColor = dimensionLabelTextColor
        let sectionTextColor = billboardAccentColor.withAlphaComponent(0.70)
        let separatorColor = billboardAccentColor.withAlphaComponent(0.25)

        // -- Text mesh helpers --
        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        // -- Build section data --
        struct DataLine { let label: String; let value: String }
        struct Section { let title: String; let lines: [DataLine] }

        let wVal = formatDimensionValue(storedWidth)
        let hVal = formatDimensionValue(storedHeight)
        let lVal = formatDimensionValue(storedLength)
        let unit = storedUnit.rawValue

        let volValue = storedUnit.convertVolume(cubicMeters: boundingBox.volume)
        let volStr: String
        if volValue >= 1000 { volStr = String(format: "%.0f %@", volValue, storedUnit.volumeUnit()) }
        else if volValue >= 100 { volStr = String(format: "%.1f %@", volValue, storedUnit.volumeUnit()) }
        else { volStr = String(format: "%.2f %@", volValue, storedUnit.volumeUnit()) }

        var sections: [Section] = [
            Section(title: "DIMENSIONS", lines: [
                DataLine(label: "WIDTH", value: "\(wVal) \(unit)"),
                DataLine(label: "HEIGHT", value: "\(hVal) \(unit)"),
                DataLine(label: "LENGTH", value: "\(lVal) \(unit)"),
                DataLine(label: "VOLUME", value: volStr),
                DataLine(label: "VOL.WT", value: storedUnit.formatVolumetricWeight(cubicMeters: boundingBox.volume)),
                DataLine(label: "SIZE", value: ShippingSize.classify(boundingBox: boundingBox).rawValue),
            ])
        ]
        if !animateLabelSection, let ld = storedLabelData, !ld.displayFields.isEmpty {
            sections.append(Section(title: "LABEL DATA", lines: ld.displayFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }
        if !storedQualityLabel.isEmpty {
            sections.append(Section(title: "QUALITY", lines: [
                DataLine(label: "QUALITY", value: storedQualityLabel),
                DataLine(label: "POINTS", value: "\(storedPointCount)"),
            ]))
        }

        // -- Pre-generate all text entities --
        let idResult = textMesh(String(format: "#%03d", boxId), size: billboardIdFontSize, weight: .bold, color: billboardAccentColor)

        var sectionHeaders: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        var sectionLines: [[(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))]] = []
        var maxLabelWidth: Float = 0
        var maxContentWidth: Float = idResult.size.x

        for section in sections {
            let header = textMesh(section.title, size: billboardSectionFontSize, weight: .bold, color: sectionTextColor)
            sectionHeaders.append(header)
            maxContentWidth = max(maxContentWidth, header.size.x)

            var lines: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
            for dl in section.lines {
                let l = textMesh(dl.label, size: billboardBodyFontSize, weight: .semibold, color: labelColor)
                let v = textMesh(dl.value, size: billboardBodyFontSize, weight: .medium, color: valueColor)
                maxLabelWidth = max(maxLabelWidth, l.size.x)
                lines.append((l, v))
            }
            sectionLines.append(lines)
        }

        // -- DESCRIPTION section (VLM-generated, word-wrapped multi-line text) --
        // Manually word-wrap the description into single-line meshes that lay
        // out the same way as every other text row in this billboard. We avoid
        // `MeshResource.generateText(containerFrame:)` because its bounds /
        // origin convention for wrapped multi-line text isn't reliable here —
        // it left the reserved area empty inside the billboard and rendered
        // the text below the billboard's bottom edge.
        let descWrapWidth: CGFloat = 0.085
        var descSectionHeader: (entity: ModelEntity, size: SIMD3<Float>)?
        var descLines: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        if let desc = storedDescription, !desc.isEmpty {
            let h = textMesh("DESCRIPTION", size: billboardSectionFontSize, weight: .bold, color: sectionTextColor)
            descSectionHeader = h
            maxContentWidth = max(maxContentWidth, h.size.x)

            let descFont = UIFont.monospacedSystemFont(ofSize: billboardBodyFontSize, weight: .regular)
            let wrapped = Self.wordWrap(desc, font: descFont, maxWidth: descWrapWidth)
            for line in wrapped {
                let r = textMesh(line, size: billboardBodyFontSize, weight: .regular, color: valueColor)
                descLines.append(r)
                maxContentWidth = max(maxContentWidth, r.size.x)
            }
        }

        // -- Animated label section (blue-styled, for expand animation) --
        var labelAnimMainHeader: (entity: ModelEntity, size: SIMD3<Float>)?
        var labelAnimSectionHeaders: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        var labelAnimSectionLines: [[(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))]] = []
        var labelAnimBannerText: (entity: ModelEntity, size: SIMD3<Float>)?
        var labelAnimBannerBgColor: UIColor?
        var labelAnimBannerTotalHeight: Float = 0
        var labelSectionHeight: Float = 0
        let thickSeparatorThick: Float = 0.001

        if animateLabelSection, let ld = storedLabelData {
            let labelAccent = UIColor(hex: 0x00BFFF)
            let lLabelColor = labelAccent.withAlphaComponent(0.55)
            let lSectionTextColor = labelAccent.withAlphaComponent(0.70)
            let highlightLabelColor = labelAccent.withAlphaComponent(0.85)
            let highlightValueColor = labelAccent
            let primaryFontSize: CGFloat = 0.012
            let bannerPadV: Float = 0.003
            let bannerGap: Float = 0.004

            // Banner

            // LABEL header
            labelAnimMainHeader = textMesh("LABEL", size: billboardIdFontSize, weight: .bold, color: labelAccent)
            maxContentWidth = max(maxContentWidth, labelAnimMainHeader!.size.x)

            // Build PRIMARY / DETAILS subsections
            let primaryFields = ld.primaryDisplayFields
            let secondaryFields = ld.secondaryDisplayFields

            struct LabelLine { let label: String; let value: String }
            struct LabelSec { let title: String; let lines: [LabelLine]; let isPrimary: Bool }
            var lSections: [LabelSec] = []
            if !primaryFields.isEmpty {
                lSections.append(LabelSec(title: "PRIMARY", lines: primaryFields.map {
                    LabelLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
                }, isPrimary: true))
            }
            if !secondaryFields.isEmpty {
                lSections.append(LabelSec(title: "DETAILS", lines: secondaryFields.map {
                    LabelLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
                }, isPrimary: false))
            }
            if lSections.isEmpty {
                let rawLines = ld.rawText.components(separatedBy: "\n").prefix(6)
                lSections.append(LabelSec(title: "RAW TEXT", lines: rawLines.enumerated().map {
                    LabelLine(label: "L\($0.offset + 1)", value: String($0.element.prefix(24)))
                }, isPrimary: false))
            }

            for section in lSections {
                let header = textMesh(section.title, size: billboardSectionFontSize, weight: .bold, color: lSectionTextColor)
                labelAnimSectionHeaders.append(header)
                maxContentWidth = max(maxContentWidth, header.size.x)

                let fontSize = section.isPrimary ? primaryFontSize : billboardBodyFontSize
                var lines: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
                for dl in section.lines {
                    let isHighlight = Self.isHighlightLabel(dl.label)
                    let lColor = isHighlight ? highlightLabelColor : lLabelColor
                    let vColor = isHighlight ? highlightValueColor : valueColor
                    let vWeight: UIFont.Weight = isHighlight ? .bold : .medium
                    let l = textMesh(dl.label, size: fontSize, weight: .semibold, color: lColor)
                    let v = textMesh(dl.value, size: fontSize, weight: vWeight, color: vColor)
                    maxLabelWidth = max(maxLabelWidth, l.size.x)
                    lines.append((l, v))
                }
                labelAnimSectionLines.append(lines)
            }

            // Label section height
            labelSectionHeight += labelAnimBannerTotalHeight
            labelSectionHeight += thickSeparatorThick + sectionTopGap
            if let lh = labelAnimMainHeader {
                labelSectionHeight += lh.size.y
            }
            for (si, section) in labelAnimSectionLines.enumerated() {
                labelSectionHeight += sectionTopGap
                labelSectionHeight += separatorThick + separatorMargin
                labelSectionHeight += labelAnimSectionHeaders[si].size.y
                for pair in section {
                    labelSectionHeight += lineGap
                    labelSectionHeight += max(pair.label.size.y, pair.value.size.y)
                }
            }
        }

        // Recalculate max width with label+gap+value
        for sl in sectionLines {
            for pair in sl {
                maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
            }
        }
        for sl in labelAnimSectionLines {
            for pair in sl {
                maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
            }
        }

        // -- Calculate total content height --
        var totalContentHeight: Float = idResult.size.y
        for (si, sl) in sectionLines.enumerated() {
            totalContentHeight += sectionTopGap
            totalContentHeight += separatorThick + separatorMargin
            totalContentHeight += sectionHeaders[si].size.y
            for pair in sl {
                totalContentHeight += lineGap
                totalContentHeight += max(pair.label.size.y, pair.value.size.y)
            }
        }
        if let h = descSectionHeader, !descLines.isEmpty {
            totalContentHeight += sectionTopGap
            totalContentHeight += separatorThick + separatorMargin
            totalContentHeight += h.size.y
            for line in descLines {
                totalContentHeight += lineGap
                totalContentHeight += line.size.y
            }
        }
        totalContentHeight += labelSectionHeight

        // -- Layout dimensions --
        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        // Store layout metrics for later expansion
        currentTotalHeight = totalHeight
        currentTotalWidth = totalWidth
        currentMaxContentWidth = maxContentWidth
        currentMaxLabelWidth = maxLabelWidth

        // -- Structural entities --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding
        let valueLeftX = textLeftX + maxLabelWidth + labelValueGap

        // Outer glow
        let glowPad: Float = 0.003
        let glowMesh = MeshResource.generateBox(
            size: [totalWidth + glowPad * 2, totalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var glowMat = UnlitMaterial(color: billboardAccentColor.withAlphaComponent(0.06))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let newGlowEntity = ModelEntity(mesh: glowMesh, materials: [glowMat])
        newGlowEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.002)
        self.glowEntity = newGlowEntity

        // Dark glass background
        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: dimensionLabelBackgroundColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let newBgEntity = ModelEntity(mesh: bgMesh, materials: [bgMat])
        newBgEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)
        self.bgEntity = newBgEntity

        // Accent bar + glow
        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let newAccentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: billboardAccentColor)])
        newAccentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)
        self.accentEntity = newAccentEntity

        let accentGlowW: Float = 0.006
        let agMesh = MeshResource.generateBox(size: [accentGlowW, accentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var agMat = UnlitMaterial(color: billboardAccentColor.withAlphaComponent(0.10))
        agMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let newAccentGlowEntity = ModelEntity(mesh: agMesh, materials: [agMat])
        newAccentGlowEntity.position = SIMD3<Float>(accentX, totalHeight / 2, -0.0005)
        self.accentGlowEntity = newAccentGlowEntity

        // Top + bottom borders
        let borderW = totalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [borderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: billboardTopBorderColor)
            mat.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return ModelEntity(mesh: mesh, materials: [mat])
        }
        let topBorder = makeBorder(opacity: 0.50)
        topBorder.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        self.topBorderEntity = topBorder
        let bottomBorder = makeBorder(opacity: 0.30)
        bottomBorder.position = SIMD3<Float>(0, 0.0003, 0.0005)
        self.bottomBorderEntity = bottomBorder

        // Add structural entities
        containerEntity.addChild(newGlowEntity)
        containerEntity.addChild(newBgEntity)
        containerEntity.addChild(newAccentEntity)
        containerEntity.addChild(newAccentGlowEntity)
        containerEntity.addChild(topBorder)
        containerEntity.addChild(bottomBorder)

        // -- Position text top-to-bottom --
        var cursor = padding + totalContentHeight

        // Banner (if animating label section with check status)
        if animateLabelSection, let txtResult = labelAnimBannerText, let bgColor = labelAnimBannerBgColor {
            let bannerPadV: Float = 0.003
            let bannerGap: Float = 0.004
            let bannerH = txtResult.size.y + bannerPadV * 2
            let bannerW = totalWidth - padding * 0.5
            let bannerBgMesh = MeshResource.generateBox(
                size: [bannerW, bannerH, 0.0012],
                cornerRadius: bannerH * 0.2
            )
            var bannerMat = UnlitMaterial(color: bgColor)
            bannerMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
            let bannerBgEntity = ModelEntity(mesh: bannerBgMesh, materials: [bannerMat])
            let bannerCenterY = cursor - bannerH / 2
            bannerBgEntity.position = SIMD3<Float>(0, bannerCenterY, 0.0003)
            containerEntity.addChild(bannerBgEntity)
            let textY = cursor - bannerPadV - txtResult.size.y
            let textX = -txtResult.size.x / 2
            txtResult.entity.position = SIMD3<Float>(textX, textY, 0.001)
            containerEntity.addChild(txtResult.entity)
            cursor -= bannerH + bannerGap
        }

        // ID header
        cursor -= idResult.size.y
        idResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(idResult.entity)

        // Sections
        for (si, sl) in sectionLines.enumerated() {
            cursor -= sectionTopGap

            // Separator line
            let sepW = maxContentWidth
            let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
            var sepMat = UnlitMaterial(color: separatorColor)
            sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
            sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
            containerEntity.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            // Section header
            cursor -= sectionHeaders[si].size.y
            sectionHeaders[si].entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(sectionHeaders[si].entity)

            // Data lines (label in dim green, value in bright white)
            for pair in sl {
                cursor -= lineGap
                let h = max(pair.label.size.y, pair.value.size.y)
                cursor -= h
                pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
                containerEntity.addChild(pair.label.entity)
                containerEntity.addChild(pair.value.entity)
            }
        }

        // -- DESCRIPTION block: separator + header + wrapped single-line text rows --
        if let h = descSectionHeader, !descLines.isEmpty {
            cursor -= sectionTopGap
            let descSepW = maxContentWidth
            let descSepMesh = MeshResource.generateBox(size: [descSepW, separatorThick, 0.0012])
            var descSepMat = UnlitMaterial(color: separatorColor)
            descSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let descSepEntity = ModelEntity(mesh: descSepMesh, materials: [descSepMat])
            descSepEntity.position = SIMD3<Float>(textLeftX + descSepW / 2, cursor, 0.0005)
            containerEntity.addChild(descSepEntity)
            cursor -= separatorThick + separatorMargin

            cursor -= h.size.y
            h.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(h.entity)

            for line in descLines {
                cursor -= lineGap
                cursor -= line.size.y
                line.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                containerEntity.addChild(line.entity)
            }
        }

        // -- Animated label section content --
        if animateLabelSection, storedLabelData != nil {
            self.revealEntities.removeAll()
            let labelAccent = UIColor(hex: 0x00BFFF)
            let labelSeparatorColor = labelAccent.withAlphaComponent(0.25)

            // Thick separator between dimensions and label
            let thickSepW = maxContentWidth
            let thickSepMesh = MeshResource.generateBox(size: [thickSepW, thickSeparatorThick, 0.0012])
            var thickSepMat = UnlitMaterial(color: labelAccent.withAlphaComponent(0.40))
            thickSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.40))
            let thickSepEntity = ModelEntity(mesh: thickSepMesh, materials: [thickSepMat])
            thickSepEntity.position = SIMD3<Float>(textLeftX + thickSepW / 2, cursor, 0.0005)
            containerEntity.addChild(thickSepEntity)
            cursor -= thickSeparatorThick + sectionTopGap

            // LABEL header
            if let mainHeader = labelAnimMainHeader {
                cursor -= mainHeader.size.y
                mainHeader.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                containerEntity.addChild(mainHeader.entity)
            }

            // Label subsections with animated line containers
            for (si, sl) in labelAnimSectionLines.enumerated() {
                cursor -= sectionTopGap

                // Separator
                let sepW = maxContentWidth
                let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
                var sepMat = UnlitMaterial(color: labelSeparatorColor)
                sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
                let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
                sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
                containerEntity.addChild(sepEntity)
                cursor -= separatorThick + separatorMargin

                // Section header
                cursor -= labelAnimSectionHeaders[si].size.y
                labelAnimSectionHeaders[si].entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                containerEntity.addChild(labelAnimSectionHeaders[si].entity)

                // Data lines in containers for stagger reveal
                for pair in sl {
                    cursor -= lineGap
                    let h = max(pair.label.size.y, pair.value.size.y)
                    cursor -= h

                    let lineContainer = Entity()
                    pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                    pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
                    lineContainer.addChild(pair.label.entity)
                    lineContainer.addChild(pair.value.entity)
                    lineContainer.scale = .zero
                    containerEntity.addChild(lineContainer)
                    self.revealEntities.append(lineContainer)
                }
            }
        }

        return containerEntity
    }

    // MARK: - Label Expansion (Warehouse Mode)

    /// Expand the dimension billboard to include label data below dimensions.
    /// Rebuilds the entire billboard using createDimensionBillboard with the combined layout,
    /// then animates the label section lines with staggered reveal.
    func expandWithLabelData(_ labelData: LabelData, boxId: Int, volume: Float, completion: @escaping () -> Void) {
        isExpandedWithLabel = true
        storedLabelData = labelData
        self.boxId = boxId

        // Remove old billboard entirely
        dimensionBillboardEntity?.removeFromParent()
        dimensionBillboardEntity = nil
        actionIconRow = nil
        billboardContainerEntity = nil
        bgEntity = nil
        glowEntity = nil
        accentEntity = nil
        accentGlowEntity = nil
        topBorderEntity = nil
        bottomBorderEntity = nil

        // Rebuild with combined layout (dimensions + label), label lines hidden for animation
        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        dimensionBillboardEntity = createDimensionBillboard(at: billboardPos, animateLabelSection: true)
        entity.addChild(dimensionBillboardEntity!)
        dimensionBillboardEntity?.isEnabled = true

        // Update action mode
        currentActionMode = .labelExpanded
        updateActionMode(.labelExpanded)

        // Animate: stagger-reveal label text lines
        revealLabelLines(completion: completion)
    }

    /// Stagger-reveal label text lines after expansion animation
    private func revealLabelLines(completion: @escaping () -> Void) {
        let stagger = PMTheme.labelBillboardRevealStagger
        let lineDuration: Double = 0.15

        for (index, lineEntity) in revealEntities.enumerated() {
            let delay = Double(index) * stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let startTime = Date()
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
                    let elapsed = Date().timeIntervalSince(startTime)
                    let t = Float(min(elapsed / lineDuration, 1.0))
                    let eased = 1.0 - pow(1.0 - t, 3)
                    lineEntity.scale = SIMD3<Float>(repeating: eased)

                    if t >= 1.0 {
                        timer.invalidate()
                        lineEntity.scale = .one
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        let totalDelay = Double(revealEntities.count) * stagger + lineDuration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
            completion()
        }
    }

    /// Set (or clear) the VLM-generated description shown under the dimensions.
    /// Triggers a rebuild of the dimension billboard so the new section appears.
    /// Safe to call multiple times; passing the same string is a no-op.
    func updateDescription(_ description: String?) {
        let normalized = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (normalized?.isEmpty == false) ? normalized : nil
        if next == storedDescription { return }
        storedDescription = next
        rebuildDimensionBillboardPreservingVisibility()
    }

    /// Tear down and rebuild the dimension billboard, preserving its enabled
    /// state. Used after stored billboard data changes (currently: description).
    private func rebuildDimensionBillboardPreservingVisibility() {
        let wasVisible = dimensionBillboardEntity?.isEnabled ?? false
        dimensionBillboardEntity?.removeFromParent()
        dimensionBillboardEntity = nil
        actionIconRow = nil
        billboardContainerEntity = nil
        bgEntity = nil
        glowEntity = nil
        accentEntity = nil
        accentGlowEntity = nil
        topBorderEntity = nil
        bottomBorderEntity = nil

        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        let rebuilt = createDimensionBillboard(at: billboardPos, animateLabelSection: false)
        dimensionBillboardEntity = rebuilt
        entity.addChild(rebuilt)
        // Re-apply the action icon row in its current mode (same recovery path
        // used by `createDimensionLabels`).
        updateActionMode(currentActionMode)
        rebuilt.isEnabled = wasVisible
    }

    /// Collapse the label section, returning to dimensions-only billboard.
    /// Used when user taps RESCAN in warehouse mode.
    func collapseLabelSection() {
        isExpandedWithLabel = false
        storedLabelData = nil
        revealEntities.removeAll()
        // Rebuild dimensions-only billboard
        createDimensionLabels()
    }

    private func formatDimensionValue(_ meters: Float) -> String {
        let value = storedUnit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func formatVolumeValue(_ cubicMeters: Float) -> String {
        let value = storedUnit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
            return "Vol: \(formatted) \(storedUnit.volumeUnit())"
        } else if value >= 100 {
            return String(format: "Vol: %.1f %@", value, storedUnit.volumeUnit())
        } else {
            return String(format: "Vol: %.2f %@", value, storedUnit.volumeUnit())
        }
    }
}
