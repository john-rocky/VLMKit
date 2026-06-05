//
//  CompletedBoxVisualization.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// Simplified visualization for saved/completed boxes
/// Shows dual-layer edges, corner markers, and dimension billboard (no handles or rotation ring)
class CompletedBoxVisualization {
    // MARK: - Properties

    private(set) var entity: Entity
    private var edgeEntities: [Entity] = []
    private var cornerMarkerEntities: [ModelEntity] = []
    private var dimensionBillboardEntity: Entity?
    private var billboardBackgroundEntity: ModelEntity?

    // Action icon row (for completed box actions)
    private var actionIconRow: Entity?

    // Attached label billboard (transferred from ViewModel on save)
    private(set) var attachedLabelBillboard: LabelBillboard?
    private(set) var attachedLabelBillboardAnchor: AnchorEntity?
    var hasLabelBillboard: Bool { attachedLabelBillboard != nil }

    private(set) var boundingBox: BoundingBox3D
    private(set) var boxId: Int
    private let height: Float
    private let length: Float
    private let width: Float
    private let unit: MeasurementUnit

    /// Public accessor for box ID
    var id: Int { boxId }

    // Stored data for re-edit
    private(set) var quality: MeasurementQuality
    private(set) var axisMapping: BoundingBox3D.AxisMapping
    private(set) var pointCloud: [SIMD3<Float>]?
    private(set) var floorY: Float?
    private(set) var labelData: LabelData?

    // MARK: - Constants

    // Dual-layer edges (dimmer than active box)
    private let innerEdgeColor: UIColor = PMTheme.uiEdgeInnerDim
    private let outerEdgeColor: UIColor = PMTheme.uiEdgeOuterDim
    private let innerEdgeRadius: Float = PMTheme.innerEdgeRadius
    private let outerEdgeRadius: Float = PMTheme.outerEdgeRadius

    // Corner markers (smaller, dimmer)
    private let cornerMarkerRadius: Float = PMTheme.cornerMarkerRadiusSmall
    private let cornerMarkerColor: UIColor = PMTheme.uiCornerMarkerDim

    // Label styling
    private let billboardIdFontSize: CGFloat = 0.014
    private let billboardBodyFontSize: CGFloat = 0.010
    private let labelTextColor: UIColor = PMTheme.uiBillboardText
    private let labelBackgroundColor: UIColor = PMTheme.uiBillboardBg
    private let billboardAccentColor: UIColor = PMTheme.uiBillboardAccent
    private let billboardTopBorderColor: UIColor = PMTheme.uiBillboardTopBorder

    // MARK: - Initialization

    init(
        boundingBox: BoundingBox3D,
        height: Float,
        length: Float,
        width: Float,
        unit: MeasurementUnit,
        boxId: Int = 0,
        quality: MeasurementQuality,
        axisMapping: BoundingBox3D.AxisMapping,
        pointCloud: [SIMD3<Float>]? = nil,
        floorY: Float? = nil,
        labelData: LabelData? = nil
    ) {
        self.boundingBox = boundingBox
        self.boxId = boxId
        self.height = height
        self.length = length
        self.width = width
        self.unit = unit
        self.quality = quality
        self.axisMapping = axisMapping
        self.pointCloud = pointCloud
        self.floorY = floorY
        self.labelData = labelData
        self.entity = Entity()
        createVisualization()
    }

    // MARK: - Public Methods

    func updateLabelOrientations(cameraPosition: SIMD3<Float>) {
        // Update attached label billboard orientation if present
        if let labelBB = attachedLabelBillboard {
            labelBB.updateOrientation(cameraPosition: cameraPosition)
        }

        guard let billboard = dimensionBillboardEntity else { return }

        let billboardPos = billboard.position(relativeTo: nil)
        let toCamera = cameraPosition - billboardPos
        let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

        if simd_length(toCameraHorizontal) > 0.01 {
            let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
            billboard.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    func setDimensionBillboardVisible(_ visible: Bool) {
        if hasLabelBillboard {
            // Show/hide the rich label billboard instead of the simple one
            attachedLabelBillboard?.setVisible(visible)
            // Keep simple billboard hidden when label billboard is attached
            dimensionBillboardEntity?.isEnabled = false
        } else {
            dimensionBillboardEntity?.isEnabled = visible
        }
        if !visible {
            hideActionIcons()
        }
    }

    func showActionIcons() {
        // Label billboard has built-in action icons — no-op
        if hasLabelBillboard { return }

        guard actionIconRow == nil, let billboard = dimensionBillboardEntity else { return }

        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.completedActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        billboard.addChild(row)
        actionIconRow = row
    }

    func hideActionIcons() {
        // Label billboard action icons are always visible — no-op
        if hasLabelBillboard { return }

        actionIconRow?.removeFromParent()
        actionIconRow = nil
    }

    var isShowingActionIcons: Bool {
        actionIconRow != nil || hasLabelBillboard
    }

    // MARK: - Label Billboard Attachment

    /// Attach a LabelBillboard (transferred from ViewModel on save).
    /// Swaps action icons to completed actions (re-edit / delete).
    func attachLabelBillboard(_ billboard: LabelBillboard, anchor: AnchorEntity) {
        attachedLabelBillboard = billboard
        attachedLabelBillboardAnchor = anchor
        billboard.updateActionIcons(ActionIconBuilder.completedActions)
    }

    /// Detach the label billboard without removing from scene (for re-edit transfer back).
    func detachLabelBillboard() -> (LabelBillboard, AnchorEntity)? {
        guard let billboard = attachedLabelBillboard, let anchor = attachedLabelBillboardAnchor else {
            return nil
        }
        attachedLabelBillboard = nil
        attachedLabelBillboardAnchor = nil
        return (billboard, anchor)
    }

    /// Remove the attached label billboard from the AR scene and clear references.
    func removeAttachedLabelBillboard() {
        attachedLabelBillboardAnchor?.removeFromParent()
        attachedLabelBillboard = nil
        attachedLabelBillboardAnchor = nil
    }

    func toMeasurementResult() -> MeasurementCalculator.MeasurementResult {
        var result = MeasurementCalculator.MeasurementResult(
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
        result.pointCloud = pointCloud
        return result
    }

    func isVisibleFromCamera(cameraPosition: SIMD3<Float>, cameraForward: SIMD3<Float>) -> Bool {
        let toBox = boundingBox.center - cameraPosition
        let distance = simd_length(toBox)
        let toBoxNormalized = toBox / distance
        let dot = simd_dot(toBoxNormalized, cameraForward)
        return dot > 0.3
    }

    func apparentSizeFromCamera(cameraPosition: SIMD3<Float>) -> Float {
        let distance = simd_length(boundingBox.center - cameraPosition)
        if distance < 0.01 { return 0 }
        let boxSize = boundingBox.extents.x * boundingBox.extents.y * boundingBox.extents.z
        return boxSize / (distance * distance)
    }

    // MARK: - Private Methods

    private func createVisualization() {
        createEdges()
        createCornerMarkers()
        createDimensionBillboard()
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

    private func createDualEdgeEntity(from start: SIMD3<Float>, to end: SIMD3<Float>, index: Int) -> Entity {
        let parent = Entity()
        parent.name = "completed_edge_\(index)"

        let direction = end - start
        let length = simd_length(direction)
        let midpoint = (start + end) / 2
        let orientation = calculateOrientation(direction: direction)

        // Outer glow layer (transparent like active box — glow is subtle so depth-sort issues are negligible)
        let outerMesh = MeshResource.generateBox(size: [outerEdgeRadius * 2, outerEdgeRadius * 2, length])
        var outerMaterial = UnlitMaterial(color: outerEdgeColor)
        outerMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
        outerEntity.name = "completed_edge_outer_\(index)"
        outerEntity.position = midpoint
        outerEntity.orientation = orientation

        // Inner line
        let innerMesh = MeshResource.generateBox(size: [innerEdgeRadius * 2, innerEdgeRadius * 2, length])
        let innerMaterial = UnlitMaterial(color: innerEdgeColor)
        let innerEntity = ModelEntity(mesh: innerMesh, materials: [innerMaterial])
        innerEntity.name = "completed_edge_inner_\(index)"
        innerEntity.position = midpoint
        innerEntity.orientation = orientation

        parent.addChild(outerEntity)
        parent.addChild(innerEntity)

        return parent
    }

    // MARK: - Corner Markers

    private func createCornerMarkers() {
        let corners = boundingBox.corners
        for (index, corner) in corners.enumerated() {
            let sphere = ModelEntity(
                mesh: MeshResource.generateSphere(radius: cornerMarkerRadius),
                materials: [UnlitMaterial(color: cornerMarkerColor)]
            )
            sphere.name = "completed_corner_\(index)"
            sphere.position = corner
            entity.addChild(sphere)
            cornerMarkerEntities.append(sphere)
        }
    }

    // Labels to emphasize as check items
    private static let highlightLabels: Set<String> = ["CTN ID", "BARCODE", "DEST", "SIZE"]

    private static func isHighlightLabel(_ label: String) -> Bool {
        highlightLabels.contains(label) || label.hasPrefix("BARCODE ")
    }

    // MARK: - Dimension Billboard

    private func createDimensionBillboard() {
        if labelData != nil {
            createCombinedBillboard()
        } else {
            createSimpleBillboard()
        }
    }

    /// Simple billboard with just #NNN and L/W/H (no label data)
    private func createSimpleBillboard() {
        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)

        let containerEntity = Entity()
        containerEntity.position = billboardPos

        let accentBarWidth: Float = 0.002
        let padding: Float = 0.007
        let innerPadding: Float = 0.004

        // -- Header --
        let idText = String(format: "#%03d", boxId)
        let idMesh = MeshResource.generateText(
            idText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardIdFontSize, weight: .bold),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        let idMaterial = UnlitMaterial(color: billboardAccentColor)
        let idEntity = ModelEntity(mesh: idMesh, materials: [idMaterial])
        let idWidth = idMesh.bounds.extents.x
        let idHeight = idMesh.bounds.extents.y

        // -- Body --
        let lVal = formatDimension(length)
        let wVal = formatDimension(width)
        let hVal = formatDimension(height)
        let bodyText = "L: \(lVal)  W: \(wVal)  H: \(hVal) \(unit.rawValue)"
        let bodyMesh = MeshResource.generateText(
            bodyText,
            extrusionDepth: 0.001,
            font: .monospacedDigitSystemFont(ofSize: billboardBodyFontSize, weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byWordWrapping
        )
        let bodyMaterial = UnlitMaterial(color: labelTextColor)
        let bodyEntity = ModelEntity(mesh: bodyMesh, materials: [bodyMaterial])
        let bodyWidth = bodyMesh.bounds.extents.x
        let bodyHeight = bodyMesh.bounds.extents.y

        // -- Layout --
        let gap: Float = 0.004
        let contentWidth = max(idWidth, bodyWidth)
        let contentHeight = idHeight + gap + bodyHeight
        let totalWidth = accentBarWidth + innerPadding + contentWidth + padding * 2
        let totalHeight = contentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.12

        // -- Background --
        let backgroundMesh = MeshResource.generateBox(
            size: [totalWidth, totalHeight, 0.001],
            cornerRadius: cornerRadius
        )
        var backgroundMaterial = UnlitMaterial(color: labelBackgroundColor)
        backgroundMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])
        backgroundEntity.name = "completed_billboard_bg"

        // Collision for tap detection
        let collisionShape = ShapeResource.generateBox(
            size: [totalWidth * 1.2, totalHeight * 1.2, 0.005]
        )
        backgroundEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
        billboardBackgroundEntity = backgroundEntity

        // -- Accent bar --
        let accentHeight = contentHeight + padding
        let accentMesh = MeshResource.generateBox(
            size: [accentBarWidth, accentHeight, 0.0015],
            cornerRadius: accentBarWidth * 0.4
        )
        let accentMaterial = UnlitMaterial(color: billboardAccentColor)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [accentMaterial])

        // -- Top border line --
        let topBorderMesh = MeshResource.generateBox(
            size: [totalWidth * 0.9, 0.0005, 0.0012]
        )
        var topBorderMaterial = UnlitMaterial(color: billboardTopBorderColor)
        topBorderMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let topBorderEntity = ModelEntity(mesh: topBorderMesh, materials: [topBorderMaterial])

        // -- Position everything --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding

        backgroundEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)
        topBorderEntity.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        idEntity.position = SIMD3<Float>(textLeftX, padding + bodyHeight + gap, 0)
        bodyEntity.position = SIMD3<Float>(textLeftX, padding, 0)

        containerEntity.addChild(backgroundEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(topBorderEntity)
        containerEntity.addChild(idEntity)
        containerEntity.addChild(bodyEntity)

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        dimensionBillboardEntity = containerEntity
    }

    /// Combined billboard with dimensions + label data + check banner (warehouse mode)
    private func createCombinedBillboard() {
        guard let ld = labelData else { return }

        let billboardPos = boundingBox.center + SIMD3<Float>(0, boundingBox.extents.y + 0.03, 0)
        let containerEntity = Entity()
        containerEntity.position = billboardPos

        // Layout constants
        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let labelValueGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001
        let thickSeparatorThick: Float = 0.001

        let dimAccent = billboardAccentColor
        let labelAccent = UIColor(hex: 0x00BFFF)
        let dimBorder = dimAccent.withAlphaComponent(0.40)

        let dimLabelColor = dimAccent.withAlphaComponent(0.55)
        let dimValueColor = labelTextColor
        let dimSectionTextColor = dimAccent.withAlphaComponent(0.70)
        let dimSeparatorColor = dimAccent.withAlphaComponent(0.25)

        let lblLabelColor = labelAccent.withAlphaComponent(0.55)
        let lblValueColor = labelTextColor
        let lblSectionTextColor = labelAccent.withAlphaComponent(0.70)
        let lblSeparatorColor = labelAccent.withAlphaComponent(0.25)
        let highlightLblColor = labelAccent.withAlphaComponent(0.85)
        let highlightLblValue = labelAccent

        let headerFontSize: CGFloat = 0.012
        let primaryFontSize: CGFloat = 0.012
        let sectionFontSize: CGFloat = 0.007

        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        struct DataLine { let label: String; let value: String }

        // -- Build dimension data --
        let wVal = formatDimension(width)
        let hVal = formatDimension(height)
        let lVal = formatDimension(length)
        let unitStr = unit.rawValue
        let vol = boundingBox.volume
        let volValue = unit.convertVolume(cubicMeters: vol)
        let volStr: String
        if volValue >= 1000 { volStr = String(format: "%.0f %@", volValue, unit.volumeUnit()) }
        else if volValue >= 100 { volStr = String(format: "%.1f %@", volValue, unit.volumeUnit()) }
        else { volStr = String(format: "%.2f %@", volValue, unit.volumeUnit()) }

        let dimLines: [DataLine] = [
            DataLine(label: "WIDTH", value: "\(wVal) \(unitStr)"),
            DataLine(label: "HEIGHT", value: "\(hVal) \(unitStr)"),
            DataLine(label: "LENGTH", value: "\(lVal) \(unitStr)"),
            DataLine(label: "VOLUME", value: volStr),
            DataLine(label: "VOL.WT", value: unit.formatVolumetricWeight(cubicMeters: vol)),
            DataLine(label: "SIZE", value: ShippingSize.classify(boundingBox: boundingBox).rawValue),
        ]

        // -- Build label data sections --
        let primaryFields = ld.primaryDisplayFields
        let secondaryFields = ld.secondaryDisplayFields
        var labelSections: [(title: String, lines: [DataLine])] = []
        if !primaryFields.isEmpty {
            labelSections.append(("PRIMARY", primaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }
        if !secondaryFields.isEmpty {
            labelSections.append(("DETAILS", secondaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }
        if labelSections.isEmpty {
            let rawLines = ld.rawText.components(separatedBy: "\n").prefix(6)
            labelSections.append(("RAW TEXT", rawLines.enumerated().map {
                DataLine(label: "L\($0.offset + 1)", value: String($0.element.prefix(24)))
            }))
        }

        // -- Check status banner --
        let bannerPadV: Float = 0.003
        let bannerGap: Float = 0.004
        var bannerTextResult: (entity: ModelEntity, size: SIMD3<Float>)?
        var bannerBgColor: UIColor?
        var bannerTotalHeight: Float = 0


        // -- Pre-generate all text entities --
        let idResult = textMesh(String(format: "#%03d", boxId), size: headerFontSize, weight: .bold, color: dimAccent)
        let dimHeader = textMesh("DIMENSIONS", size: sectionFontSize, weight: .bold, color: dimSectionTextColor)
        let labelHeader = textMesh("LABEL", size: headerFontSize, weight: .bold, color: labelAccent)

        // Dimension lines
        var dimLinePairs: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
        var maxLabelWidth: Float = 0
        for dl in dimLines {
            let isHighlight = Self.isHighlightLabel(dl.label)
            let lColor = isHighlight ? dimAccent.withAlphaComponent(0.85) : dimLabelColor
            var vColor = isHighlight ? dimAccent : dimValueColor
            let vWeight: UIFont.Weight = isHighlight ? .bold : .medium
            let l = textMesh(dl.label, size: primaryFontSize, weight: .semibold, color: lColor)
            let v = textMesh(dl.value, size: primaryFontSize, weight: vWeight, color: vColor)
            maxLabelWidth = max(maxLabelWidth, l.size.x)
            dimLinePairs.append((l, v))
        }

        // Label section lines
        var labelSectionHeaders: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        var labelSectionLines: [[(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))]] = []
        for section in labelSections {
            let header = textMesh(section.title, size: sectionFontSize, weight: .bold, color: lblSectionTextColor)
            labelSectionHeaders.append(header)
            let fontSize = section.title == "PRIMARY" ? primaryFontSize : billboardBodyFontSize
            var lines: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
            for dl in section.lines {
                let isHighlight = Self.isHighlightLabel(dl.label)
                let lColor = isHighlight ? highlightLblColor : lblLabelColor
                let vColor = isHighlight ? highlightLblValue : lblValueColor
                let vWeight: UIFont.Weight = isHighlight ? .bold : .medium
                let l = textMesh(dl.label, size: fontSize, weight: .semibold, color: lColor)
                let v = textMesh(dl.value, size: fontSize, weight: vWeight, color: vColor)
                maxLabelWidth = max(maxLabelWidth, l.size.x)
                lines.append((l, v))
            }
            labelSectionLines.append(lines)
        }

        // -- Calculate widths --
        var maxContentWidth: Float = max(idResult.size.x, dimHeader.size.x, labelHeader.size.x)
        if let txtResult = bannerTextResult {
            maxContentWidth = max(maxContentWidth, txtResult.size.x)
        }
        for pair in dimLinePairs {
            maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
        }
        for sh in labelSectionHeaders { maxContentWidth = max(maxContentWidth, sh.size.x) }
        for sl in labelSectionLines {
            for pair in sl {
                maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
            }
        }

        // -- Calculate total content height --
        var totalContentHeight: Float = bannerTotalHeight
        totalContentHeight += idResult.size.y  // #NNN
        totalContentHeight += sectionTopGap + separatorThick + separatorMargin + dimHeader.size.y
        for pair in dimLinePairs {
            totalContentHeight += lineGap + max(pair.label.size.y, pair.value.size.y)
        }
        // Thick separator + LABEL header
        totalContentHeight += sectionTopGap + thickSeparatorThick + sectionTopGap + labelHeader.size.y
        for (si, sl) in labelSectionLines.enumerated() {
            totalContentHeight += sectionTopGap + separatorThick + separatorMargin + labelSectionHeaders[si].size.y
            for pair in sl {
                totalContentHeight += lineGap + max(pair.label.size.y, pair.value.size.y)
            }
        }

        // -- Layout dimensions --
        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding
        let valueLeftX = textLeftX + maxLabelWidth + labelValueGap

        // -- Structural entities --
        let glowPad: Float = 0.003
        let glowMesh = MeshResource.generateBox(
            size: [totalWidth + glowPad * 2, totalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var glowMat = UnlitMaterial(color: dimAccent.withAlphaComponent(0.06))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let glowEntity = ModelEntity(mesh: glowMesh, materials: [glowMat])
        glowEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.002)

        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: labelBackgroundColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMat])
        bgEntity.name = "completed_billboard_bg"
        bgEntity.position = SIMD3<Float>(0, totalHeight / 2, -0.001)

        let collisionShape = ShapeResource.generateBox(size: [totalWidth * 1.2, totalHeight * 1.2, 0.005])
        bgEntity.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])
        billboardBackgroundEntity = bgEntity

        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accentEntity = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: dimAccent)])
        accentEntity.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)

        let accentGlowW: Float = 0.006
        let agMesh = MeshResource.generateBox(size: [accentGlowW, accentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var agMat = UnlitMaterial(color: dimAccent.withAlphaComponent(0.10))
        agMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let accentGlowEntity = ModelEntity(mesh: agMesh, materials: [agMat])
        accentGlowEntity.position = SIMD3<Float>(accentX, totalHeight / 2, -0.0005)

        let borderW = totalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [borderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: dimBorder)
            mat.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return ModelEntity(mesh: mesh, materials: [mat])
        }
        let topBorder = makeBorder(opacity: 0.50)
        topBorder.position = SIMD3<Float>(0, totalHeight - 0.0003, 0.0005)
        let bottomBorder = makeBorder(opacity: 0.30)
        bottomBorder.position = SIMD3<Float>(0, 0.0003, 0.0005)

        containerEntity.addChild(glowEntity)
        containerEntity.addChild(bgEntity)
        containerEntity.addChild(accentEntity)
        containerEntity.addChild(accentGlowEntity)
        containerEntity.addChild(topBorder)
        containerEntity.addChild(bottomBorder)

        // -- Position text top-to-bottom --
        var cursor = padding + totalContentHeight

        // Check status banner
        if let txtResult = bannerTextResult, let bgColor = bannerBgColor {
            let bannerH = txtResult.size.y + bannerPadV * 2
            let bannerW = totalWidth - padding * 0.5
            let bannerBgMesh = MeshResource.generateBox(size: [bannerW, bannerH, 0.0012], cornerRadius: bannerH * 0.2)
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

        // #NNN header
        cursor -= idResult.size.y
        idResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(idResult.entity)

        // DIMENSIONS section
        cursor -= sectionTopGap
        let dimSepW = maxContentWidth
        let dimSepMesh = MeshResource.generateBox(size: [dimSepW, separatorThick, 0.0012])
        var dimSepMat = UnlitMaterial(color: dimSeparatorColor)
        dimSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let dimSepEntity = ModelEntity(mesh: dimSepMesh, materials: [dimSepMat])
        dimSepEntity.position = SIMD3<Float>(textLeftX + dimSepW / 2, cursor, 0.0005)
        containerEntity.addChild(dimSepEntity)
        cursor -= separatorThick + separatorMargin

        cursor -= dimHeader.size.y
        dimHeader.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(dimHeader.entity)

        for pair in dimLinePairs {
            cursor -= lineGap
            let h = max(pair.label.size.y, pair.value.size.y)
            cursor -= h
            pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
            containerEntity.addChild(pair.label.entity)
            containerEntity.addChild(pair.value.entity)
        }

        // Thick separator between dimensions and label
        cursor -= sectionTopGap
        let thickSepW = maxContentWidth
        let thickSepMesh = MeshResource.generateBox(size: [thickSepW, thickSeparatorThick, 0.0012])
        var thickSepMat = UnlitMaterial(color: labelAccent.withAlphaComponent(0.40))
        thickSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let thickSepEntity = ModelEntity(mesh: thickSepMesh, materials: [thickSepMat])
        thickSepEntity.position = SIMD3<Float>(textLeftX + thickSepW / 2, cursor, 0.0005)
        containerEntity.addChild(thickSepEntity)
        cursor -= thickSeparatorThick + sectionTopGap

        // LABEL header
        cursor -= labelHeader.size.y
        labelHeader.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        containerEntity.addChild(labelHeader.entity)

        // Label data sections
        for (si, sl) in labelSectionLines.enumerated() {
            cursor -= sectionTopGap
            let sepW = maxContentWidth
            let sepMesh = MeshResource.generateBox(size: [sepW, separatorThick, 0.0012])
            var sepMat = UnlitMaterial(color: lblSeparatorColor)
            sepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            let sepEntity = ModelEntity(mesh: sepMesh, materials: [sepMat])
            sepEntity.position = SIMD3<Float>(textLeftX + sepW / 2, cursor, 0.0005)
            containerEntity.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            cursor -= labelSectionHeaders[si].size.y
            labelSectionHeaders[si].entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            containerEntity.addChild(labelSectionHeaders[si].entity)

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

        // Initially hidden
        containerEntity.isEnabled = false

        entity.addChild(containerEntity)
        dimensionBillboardEntity = containerEntity
    }

    private func formatDimension(_ meters: Float) -> String {
        let value = unit.convert(meters: meters)
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }

    private func formatVolume() -> String {
        let cubicMeters = height * length * width
        let value = unit.convertVolume(cubicMeters: cubicMeters)
        if value >= 1000 {
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
            return "Vol: \(formatted) \(unit.volumeUnit())"
        } else if value >= 100 {
            return String(format: "Vol: %.1f %@", value, unit.volumeUnit())
        } else {
            return String(format: "Vol: %.2f %@", value, unit.volumeUnit())
        }
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
}
