//
//  LabelBillboard.swift
//  SnapMeasure
//

import RealityKit
import UIKit
import simd

/// AR billboard that displays parsed label data floating above the real label in 3D space.
/// Styled with neon blue (0x00BFFF) cyberpunk aesthetic, modeled after BoxVisualization billboard.
/// After measurement, can expand to show dimensions in a unified layout via `expandWithDimensions()`.
class LabelBillboard {

    private(set) var entity: Entity

    // Text line entities for staggered reveal animation
    private var revealEntities: [Entity] = []

    // Action icon row
    private var actionIconRow: Entity?

    // Stored references for expansion
    private var labelData: LabelData
    private var containerEntity: Entity?

    // Structural entity references (for in-place expansion)
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

    // Placeholder dimension section (shown before measurement)
    private var placeholderGroup: Entity?
    private var placeholderSectionHeight: Float = 0

    /// Whether this billboard has been expanded with dimensions
    private(set) var isUnified: Bool = false

    // Stored dimension values (populated on expand)
    private var storedHeight: Float = 0
    private var storedLength: Float = 0
    private var storedWidth: Float = 0
    private var storedUnit: MeasurementUnit = .centimeters
    private var storedBoxId: Int = 0
    private var storedVolume: Float = 0
    private var storedQualityLabel: String = ""
    private var storedPointCount: Int = 0

    // Colors (neon blue theme)
    private let accentColor = UIColor(hex: 0x00BFFF)
    private let bgColor = PMTheme.uiBillboardBg
    private let textColor = PMTheme.uiBillboardText
    private let borderColor = UIColor(hex: 0x00BFFF).withAlphaComponent(0.40)

    // Font sizes
    private let headerFontSize: CGFloat = 0.012
    private let primaryFontSize: CGFloat = 0.012
    private let bodyFontSize: CGFloat = 0.010
    private let sectionFontSize: CGFloat = 0.007

    // Labels to emphasize as check items (rendered with accent color + bold weight)
    private static let highlightLabels: Set<String> = ["CTN ID", "BARCODE", "DEST", "SIZE"]

    /// Returns true if a label (or BARCODE N variant) should be highlighted
    private static func isHighlightLabel(_ label: String) -> Bool {
        highlightLabels.contains(label) || label.hasPrefix("BARCODE ")
    }

    init(labelData: LabelData, worldPosition: SIMD3<Float>, surfaceNormal: SIMD3<Float>) {
        self.labelData = labelData
        self.entity = Entity()
        entity.position = worldPosition
        buildBillboard(labelData: labelData)
    }

    // MARK: - Build

    private func buildBillboard(labelData: LabelData) {
        let container = Entity()
        container.name = "label_billboard_container"
        self.containerEntity = container

        // Layout constants
        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let labelValueGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001

        // Cyber colors (neon blue)
        let labelColor = accentColor.withAlphaComponent(0.55)
        let valueColor = textColor
        let sectionTextColor = accentColor.withAlphaComponent(0.70)
        let separatorColor = accentColor.withAlphaComponent(0.25)

        // -- Text mesh helper --
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

        // Highlight colors for check items (brighter accent)
        let highlightLabelColor = accentColor.withAlphaComponent(0.85)
        let highlightValueColor = accentColor

        let primaryFields = labelData.primaryDisplayFields
        let secondaryFields = labelData.secondaryDisplayFields

        var sections: [Section] = []
        if !primaryFields.isEmpty {
            sections.append(Section(title: "PRIMARY", lines: primaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }
        if !secondaryFields.isEmpty {
            sections.append(Section(title: "DETAILS", lines: secondaryFields.map {
                DataLine(label: $0.label, value: $0.value.count > 24 ? String($0.value.prefix(24)) : $0.value)
            }))
        }

        // Fallback if no structured fields
        if sections.isEmpty {
            let rawLines = labelData.rawText.components(separatedBy: "\n").prefix(6)
            sections.append(Section(title: "RAW TEXT", lines: rawLines.enumerated().map {
                DataLine(label: "L\($0.offset + 1)", value: String($0.element.prefix(24)))
            }))
        }

        // -- Pre-generate all text entities --
        let headerResult = textMesh("LABEL", size: headerFontSize, weight: .bold, color: accentColor)

        var sectionHeaders: [(entity: ModelEntity, size: SIMD3<Float>)] = []
        var sectionLines: [[(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))]] = []
        var maxLabelWidth: Float = 0
        var maxContentWidth: Float = headerResult.size.x

        for section in sections {
            let header = textMesh(section.title, size: sectionFontSize, weight: .bold, color: sectionTextColor)
            sectionHeaders.append(header)
            maxContentWidth = max(maxContentWidth, header.size.x)

            let fontSize = section.title == "PRIMARY" ? primaryFontSize : bodyFontSize
            var lines: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
            for dl in section.lines {
                let isHighlight = Self.isHighlightLabel(dl.label)
                let lColor = isHighlight ? highlightLabelColor : labelColor
                let vColor = isHighlight ? highlightValueColor : valueColor
                let vWeight: UIFont.Weight = isHighlight ? .bold : .medium
                let l = textMesh(dl.label, size: fontSize, weight: .semibold, color: lColor)
                let v = textMesh(dl.value, size: fontSize, weight: vWeight, color: vColor)
                maxLabelWidth = max(maxLabelWidth, l.size.x)
                lines.append((l, v))
            }
            sectionLines.append(lines)
        }

        // Recalculate max width with label+gap+value
        for sl in sectionLines {
            for pair in sl {
                maxContentWidth = max(maxContentWidth, maxLabelWidth + labelValueGap + pair.value.size.x)
            }
        }

        // -- Calculate total content height --
        var totalContentHeight: Float = headerResult.size.y
        for (si, sl) in sectionLines.enumerated() {
            totalContentHeight += sectionTopGap
            totalContentHeight += separatorThick + separatorMargin
            totalContentHeight += sectionHeaders[si].size.y
            for pair in sl {
                totalContentHeight += lineGap
                totalContentHeight += max(pair.label.size.y, pair.value.size.y)
            }
        }

        // -- Build placeholder dimension section (shown before measurement) --
        let thickSeparatorThick: Float = 0.001
        let phAccent = PMTheme.uiCyan

        let phPrompt = textMesh("TAP TO MEASURE", size: headerFontSize, weight: .bold,
                                color: phAccent.withAlphaComponent(0.55))
        let phDimHeader = textMesh("DIMENSIONS", size: sectionFontSize, weight: .bold,
                                   color: phAccent.withAlphaComponent(0.30))

        let phLabels = ["WIDTH", "HEIGHT", "LENGTH", "VOLUME", "VOL.WT", "SIZE"]
        var phLinePairs: [(label: (entity: ModelEntity, size: SIMD3<Float>),
                           value: (entity: ModelEntity, size: SIMD3<Float>))] = []

        for label in phLabels {
            let l = textMesh(label, size: primaryFontSize, weight: .semibold,
                            color: phAccent.withAlphaComponent(0.25))
            let v = textMesh("---", size: primaryFontSize, weight: .medium,
                            color: phAccent.withAlphaComponent(0.20))
            phLinePairs.append((l, v))
        }

        // Calculate placeholder section height
        var phHeight: Float = phPrompt.size.y
        phHeight += sectionTopGap
        phHeight += separatorThick + separatorMargin
        phHeight += phDimHeader.size.y
        for pair in phLinePairs {
            phHeight += lineGap
            phHeight += max(pair.label.size.y, pair.value.size.y)
        }
        phHeight += sectionTopGap + thickSeparatorThick
        placeholderSectionHeight = phHeight

        // Add placeholder height to total content
        totalContentHeight += placeholderSectionHeight + sectionTopGap

        // Update width if placeholder text is wider
        maxContentWidth = max(maxContentWidth, phPrompt.size.x)

        // -- Layout dimensions --
        let totalWidth = accentBarWidth + innerPadding + maxContentWidth + padding * 2
        let totalHeight = totalContentHeight + padding * 2
        let cornerRadius = min(totalHeight, totalWidth) * 0.06

        // -- Structural entities --
        let leftEdge = -totalWidth / 2
        let accentX = leftEdge + padding / 2 + accentBarWidth / 2
        let textLeftX = leftEdge + padding + accentBarWidth + innerPadding
        let valueLeftX = textLeftX + maxLabelWidth + labelValueGap

        // Store layout metrics for later expansion
        currentTotalHeight = totalHeight
        currentTotalWidth = totalWidth
        currentMaxContentWidth = maxContentWidth
        currentMaxLabelWidth = maxLabelWidth

        // Outer glow
        let glowPad: Float = 0.003
        let glowMesh = MeshResource.generateBox(
            size: [totalWidth + glowPad * 2, totalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var glowMat = UnlitMaterial(color: accentColor.withAlphaComponent(0.06))
        glowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let glow = ModelEntity(mesh: glowMesh, materials: [glowMat])
        glow.position = SIMD3<Float>(0, totalHeight / 2, -0.002)
        self.glowEntity = glow

        // Dark glass background
        let bgMesh = MeshResource.generateBox(size: [totalWidth, totalHeight, 0.001], cornerRadius: cornerRadius)
        var bgMat = UnlitMaterial(color: bgColor)
        bgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let bg = ModelEntity(mesh: bgMesh, materials: [bgMat])
        bg.position = SIMD3<Float>(0, totalHeight / 2, -0.001)
        self.bgEntity = bg

        // Accent bar + glow
        let accentH = totalContentHeight + padding
        let accentMesh = MeshResource.generateBox(size: [accentBarWidth, accentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let accent = ModelEntity(mesh: accentMesh, materials: [UnlitMaterial(color: accentColor)])
        accent.position = SIMD3<Float>(accentX, totalHeight / 2, 0.0)
        self.accentEntity = accent

        let accentGlowW: Float = 0.006
        let agMesh = MeshResource.generateBox(size: [accentGlowW, accentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var agMat = UnlitMaterial(color: accentColor.withAlphaComponent(0.10))
        agMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let accentGlow = ModelEntity(mesh: agMesh, materials: [agMat])
        accentGlow.position = SIMD3<Float>(accentX, totalHeight / 2, -0.0005)
        self.accentGlowEntity = accentGlow

        // Top + bottom borders
        let borderW = totalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [borderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: borderColor)
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
        container.addChild(glow)
        container.addChild(bg)
        container.addChild(accent)
        container.addChild(accentGlow)
        container.addChild(topBorder)
        container.addChild(bottomBorder)

        // -- Position text top-to-bottom --
        var cursor = padding + totalContentHeight

        // -- Placeholder dimension section (top of billboard) --
        let phGroup = Entity()
        phGroup.name = "placeholder_dimensions"

        // "TAP TO MEASURE" prompt
        cursor -= phPrompt.size.y
        phPrompt.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        phGroup.addChild(phPrompt.entity)

        // Thin separator
        cursor -= sectionTopGap
        let phSepW = maxContentWidth
        let phSepMesh = MeshResource.generateBox(size: [phSepW, separatorThick, 0.0012])
        var phSepMat = UnlitMaterial(color: phAccent.withAlphaComponent(0.15))
        phSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let phSepEntity = ModelEntity(mesh: phSepMesh, materials: [phSepMat])
        phSepEntity.position = SIMD3<Float>(textLeftX + phSepW / 2, cursor, 0.0005)
        phGroup.addChild(phSepEntity)
        cursor -= separatorThick + separatorMargin

        // "DIMENSIONS" header
        cursor -= phDimHeader.size.y
        phDimHeader.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        phGroup.addChild(phDimHeader.entity)

        // Placeholder data lines (visible immediately, not stagger-revealed)
        for pair in phLinePairs {
            cursor -= lineGap
            let h = max(pair.label.size.y, pair.value.size.y)
            cursor -= h
            pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
            phGroup.addChild(pair.label.entity)
            phGroup.addChild(pair.value.entity)
        }

        // Thick separator between placeholder and label section
        cursor -= sectionTopGap
        let phThickSepW = maxContentWidth
        let phThickSepMesh = MeshResource.generateBox(size: [phThickSepW, thickSeparatorThick, 0.0012])
        var phThickSepMat = UnlitMaterial(color: phAccent.withAlphaComponent(0.15))
        phThickSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.15))
        let phThickSepEntity = ModelEntity(mesh: phThickSepMesh, materials: [phThickSepMat])
        phThickSepEntity.position = SIMD3<Float>(textLeftX + phThickSepW / 2, cursor, 0.0005)
        phGroup.addChild(phThickSepEntity)
        cursor -= thickSeparatorThick

        container.addChild(phGroup)
        placeholderGroup = phGroup

        // Gap between placeholder and label section
        cursor -= sectionTopGap

        // Header: "LABEL"
        cursor -= headerResult.size.y
        headerResult.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
        container.addChild(headerResult.entity)

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
            container.addChild(sepEntity)
            cursor -= separatorThick + separatorMargin

            // Section header
            cursor -= sectionHeaders[si].size.y
            sectionHeaders[si].entity.position = SIMD3<Float>(textLeftX, cursor, 0)
            container.addChild(sectionHeaders[si].entity)

            // Data lines
            for pair in sl {
                cursor -= lineGap
                let h = max(pair.label.size.y, pair.value.size.y)
                cursor -= h

                // Wrap each line in a container for staggered reveal
                let lineContainer = Entity()
                pair.label.entity.position = SIMD3<Float>(textLeftX, cursor, 0)
                pair.value.entity.position = SIMD3<Float>(valueLeftX, cursor, 0)
                lineContainer.addChild(pair.label.entity)
                lineContainer.addChild(pair.value.entity)
                lineContainer.scale = .zero  // Hidden initially for reveal
                container.addChild(lineContainer)
                revealEntities.append(lineContainer)
            }
        }

        // Action icon row below billboard
        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.labelBillboardActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        container.addChild(row)
        actionIconRow = row

        entity.addChild(container)

        // Start hidden (scale zero) for reveal animation
        container.scale = .zero
    }

    // MARK: - Orientation

    /// Rotate billboard to face camera (Y-axis only), same as BoxVisualization
    func updateOrientation(cameraPosition: SIMD3<Float>) {
        let billboardPos = entity.position(relativeTo: nil)
        let toCamera = cameraPosition - billboardPos
        let toCameraHorizontal = SIMD3<Float>(toCamera.x, 0, toCamera.z)

        if simd_length(toCameraHorizontal) > 0.01 {
            let angle = atan2(toCameraHorizontal.x, toCameraHorizontal.z)
            entity.orientation = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }
    }

    // MARK: - Reveal Animation

    /// Staggered reveal: billboard grows in, then text lines appear one by one
    func startRevealAnimation(completion: @escaping () -> Void) {
        guard let container = containerEntity else {
            completion()
            return
        }

        // Phase 1: Grow billboard container from zero to full scale (0.3s)
        let growDuration: Double = 0.3
        let growStart = Date()

        let growTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(growStart)
            let t = Float(min(elapsed / growDuration, 1.0))
            let eased = 1.0 - pow(1.0 - t, 3)  // easeOutCubic
            container.scale = SIMD3<Float>(repeating: eased)

            if t >= 1.0 {
                timer.invalidate()
                container.scale = .one

                // Phase 2: Staggered text line reveal
                self.revealTextLines(completion: completion)
            }
        }
        RunLoop.main.add(growTimer, forMode: .common)
    }

    private func revealTextLines(completion: @escaping () -> Void) {
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

        // Call completion after all lines have revealed
        let totalDelay = Double(revealEntities.count) * stagger + lineDuration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
            completion()
        }
    }

    // MARK: - Dimension Expansion

    /// Expand the billboard in-place to show dimensions above existing label data.
    /// Keeps existing container and label content. Replaces structural entities (bg, glow, borders)
    /// with taller green-themed versions. Dimension content appears above the label section.
    func expandWithDimensions(
        height: Float, length: Float, width: Float,
        unit: MeasurementUnit, boxId: Int, volume: Float,
        qualityLabel: String, pointCount: Int,
        completion: @escaping () -> Void
    ) {
        isUnified = true
        storedHeight = height
        storedLength = length
        storedWidth = width
        storedUnit = unit
        storedBoxId = boxId
        storedVolume = volume
        storedQualityLabel = qualityLabel
        storedPointCount = pointCount

        guard let container = containerEntity else {
            completion()
            return
        }

        // Remove placeholder dimension section
        placeholderGroup?.removeFromParent()
        placeholderGroup = nil

        let dimAccent = PMTheme.uiCyan
        let dimBorder = dimAccent.withAlphaComponent(0.40)

        // Layout constants (match buildBillboard)
        let accentBarWidth: Float = 0.002
        let padding: Float = 0.008
        let innerPadding: Float = 0.005
        let lineGap: Float = 0.004
        let sectionTopGap: Float = 0.006
        let labelValueGap: Float = 0.005
        let separatorThick: Float = 0.0004
        let separatorMargin: Float = 0.001
        let thickSeparatorThick: Float = 0.001

        let dimLabelColor = dimAccent.withAlphaComponent(0.55)
        let dimValueColor = textColor
        let dimSectionTextColor = dimAccent.withAlphaComponent(0.70)
        let dimSeparatorColor = dimAccent.withAlphaComponent(0.25)

        // Highlight colors for check items (brighter accent)
        let dimHighlightLabelColor = dimAccent.withAlphaComponent(0.85)
        let dimHighlightValueColor = dimAccent

        // Text mesh helper
        func textMesh(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> (entity: ModelEntity, size: SIMD3<Float>) {
            let mesh = MeshResource.generateText(
                text, extrusionDepth: 0.001,
                font: .monospacedSystemFont(ofSize: size, weight: weight),
                containerFrame: .zero, alignment: .left, lineBreakMode: .byTruncatingTail
            )
            return (ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]), mesh.bounds.extents)
        }

        // -- Format dimension values --
        func formatDimValue(_ meters: Float) -> String {
            let value = storedUnit.convert(meters: meters)
            if value >= 100 { return String(format: "%.0f", value) }
            else if value >= 10 { return String(format: "%.1f", value) }
            else { return String(format: "%.2f", value) }
        }

        let wVal = formatDimValue(storedWidth)
        let hVal = formatDimValue(storedHeight)
        let lVal = formatDimValue(storedLength)
        let unitStr = storedUnit.rawValue

        let volValue = storedUnit.convertVolume(cubicMeters: storedVolume)
        let volStr: String
        if volValue >= 1000 { volStr = String(format: "%.0f %@", volValue, storedUnit.volumeUnit()) }
        else if volValue >= 100 { volStr = String(format: "%.1f %@", volValue, storedUnit.volumeUnit()) }
        else { volStr = String(format: "%.2f %@", volValue, storedUnit.volumeUnit()) }

        // -- Build dimension data lines --
        struct DataLine { let label: String; let value: String }

        var dimLines: [DataLine] = [
            DataLine(label: "WIDTH", value: "\(wVal) \(unitStr)"),
            DataLine(label: "HEIGHT", value: "\(hVal) \(unitStr)"),
            DataLine(label: "LENGTH", value: "\(lVal) \(unitStr)"),
            DataLine(label: "VOLUME", value: volStr),
            DataLine(label: "VOL.WT", value: storedUnit.formatVolumetricWeight(cubicMeters: storedVolume)),
            DataLine(label: "SIZE", value: ShippingSize.classify(lengthMeters: storedLength, widthMeters: storedWidth, heightMeters: storedHeight).rawValue),
        ]

        // -- Pre-generate check status banner --
        // Full-width colored banner with icon + dark text for high visibility
        let bannerPadV: Float = 0.003
        let bannerGap: Float = 0.004   // gap below banner

        var bannerTextResult: (entity: ModelEntity, size: SIMD3<Float>)?
        var bannerBgColor: UIColor?
        var bannerTotalHeight: Float = 0

        if false { // Banner removed (was warehouse CHECK OK/NG)
        }

        // -- Pre-generate dimension text entities --
        let idResult = textMesh(String(format: "#%03d", storedBoxId), size: headerFontSize, weight: .bold, color: dimAccent)
        let dimHeader = textMesh("DIMENSIONS", size: sectionFontSize, weight: .bold, color: dimSectionTextColor)

        var dimLinePairs: [(label: (entity: ModelEntity, size: SIMD3<Float>), value: (entity: ModelEntity, size: SIMD3<Float>))] = []
        var dimMaxLabelWidth: Float = 0

        for dl in dimLines {
            let isHighlight = Self.isHighlightLabel(dl.label)
            let lColor = isHighlight ? dimHighlightLabelColor : dimLabelColor
            var vColor = isHighlight ? dimHighlightValueColor : dimValueColor
            let vWeight: UIFont.Weight = isHighlight ? .bold : .medium
            let l = textMesh(dl.label, size: primaryFontSize, weight: .semibold, color: lColor)
            let v = textMesh(dl.value, size: primaryFontSize, weight: vWeight, color: vColor)
            dimMaxLabelWidth = max(dimMaxLabelWidth, l.size.x)
            dimLinePairs.append((l, v))
        }

        // -- Calculate dimension section height --
        var dimSectionHeight: Float = bannerTotalHeight  // banner (0 if no banner)
        dimSectionHeight += idResult.size.y  // #NNN
        dimSectionHeight += sectionTopGap
        dimSectionHeight += separatorThick + separatorMargin
        dimSectionHeight += dimHeader.size.y
        for pair in dimLinePairs {
            dimSectionHeight += lineGap
            dimSectionHeight += max(pair.label.size.y, pair.value.size.y)
        }

        // Add thick separator between dimensions and label sections
        let thickSepGap: Float = sectionTopGap
        dimSectionHeight += thickSepGap + thickSeparatorThick

        // -- Calculate new billboard dimensions --
        var dimMaxContentWidth: Float = max(idResult.size.x, dimHeader.size.x)
        if let txtResult = bannerTextResult {
            dimMaxContentWidth = max(dimMaxContentWidth, txtResult.size.x)
        }
        for pair in dimLinePairs {
            dimMaxContentWidth = max(dimMaxContentWidth, dimMaxLabelWidth + labelValueGap + pair.value.size.x)
        }

        let newMaxContentWidth = max(currentMaxContentWidth, dimMaxContentWidth)
        let newMaxLabelWidth = max(currentMaxLabelWidth, dimMaxLabelWidth)
        let newTotalWidth = accentBarWidth + innerPadding + newMaxContentWidth + padding * 2
        let newTotalHeight = currentTotalHeight - placeholderSectionHeight + dimSectionHeight

        let cornerRadius = min(newTotalHeight, newTotalWidth) * 0.06
        let newLeftEdge = -newTotalWidth / 2
        let newAccentX = newLeftEdge + padding / 2 + accentBarWidth / 2
        let newTextLeftX = newLeftEdge + padding + accentBarWidth + innerPadding
        let newValueLeftX = newTextLeftX + newMaxLabelWidth + labelValueGap

        // -- Remove old structural entities --
        bgEntity?.removeFromParent()
        glowEntity?.removeFromParent()
        accentEntity?.removeFromParent()
        accentGlowEntity?.removeFromParent()
        topBorderEntity?.removeFromParent()
        bottomBorderEntity?.removeFromParent()
        actionIconRow?.removeFromParent()
        actionIconRow = nil

        // -- Create new taller structural entities with green accent --

        // Outer glow (green)
        let glowPad: Float = 0.003
        let newGlowMesh = MeshResource.generateBox(
            size: [newTotalWidth + glowPad * 2, newTotalHeight + glowPad * 2, 0.0008],
            cornerRadius: cornerRadius + glowPad * 0.5
        )
        var newGlowMat = UnlitMaterial(color: dimAccent.withAlphaComponent(0.06))
        newGlowMat.blending = .transparent(opacity: .init(floatLiteral: 0.06))
        let newGlow = ModelEntity(mesh: newGlowMesh, materials: [newGlowMat])
        newGlow.position = SIMD3<Float>(0, newTotalHeight / 2, -0.002)
        self.glowEntity = newGlow

        // Dark glass background
        let newBgMesh = MeshResource.generateBox(size: [newTotalWidth, newTotalHeight, 0.001], cornerRadius: cornerRadius)
        var newBgMat = UnlitMaterial(color: bgColor)
        newBgMat.blending = .transparent(opacity: .init(floatLiteral: 0.90))
        let newBg = ModelEntity(mesh: newBgMesh, materials: [newBgMat])
        newBg.position = SIMD3<Float>(0, newTotalHeight / 2, -0.001)
        self.bgEntity = newBg

        // Accent bar (green)
        let newAccentH = (newTotalHeight - padding * 2) + padding
        let newAccentMesh = MeshResource.generateBox(size: [accentBarWidth, newAccentH, 0.0015], cornerRadius: accentBarWidth * 0.4)
        let newAccent = ModelEntity(mesh: newAccentMesh, materials: [UnlitMaterial(color: dimAccent)])
        newAccent.position = SIMD3<Float>(newAccentX, newTotalHeight / 2, 0.0)
        self.accentEntity = newAccent

        let accentGlowW: Float = 0.006
        let newAgMesh = MeshResource.generateBox(size: [accentGlowW, newAccentH, 0.001], cornerRadius: accentGlowW * 0.3)
        var newAgMat = UnlitMaterial(color: dimAccent.withAlphaComponent(0.10))
        newAgMat.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        let newAccentGlow = ModelEntity(mesh: newAgMesh, materials: [newAgMat])
        newAccentGlow.position = SIMD3<Float>(newAccentX, newTotalHeight / 2, -0.0005)
        self.accentGlowEntity = newAccentGlow

        // Top + bottom borders (green)
        let newBorderW = newTotalWidth * 0.92
        func makeBorder(opacity: Float) -> ModelEntity {
            let mesh = MeshResource.generateBox(size: [newBorderW, 0.0006, 0.0012])
            var mat = UnlitMaterial(color: dimBorder)
            mat.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return ModelEntity(mesh: mesh, materials: [mat])
        }
        let newTopBorder = makeBorder(opacity: 0.50)
        newTopBorder.position = SIMD3<Float>(0, newTotalHeight - 0.0003, 0.0005)
        self.topBorderEntity = newTopBorder
        let newBottomBorder = makeBorder(opacity: 0.30)
        newBottomBorder.position = SIMD3<Float>(0, 0.0003, 0.0005)
        self.bottomBorderEntity = newBottomBorder

        // Add new structural entities (start at zero scale for animation)
        let structuralGroup = Entity()
        structuralGroup.name = "structural_group"
        structuralGroup.addChild(newGlow)
        structuralGroup.addChild(newBg)
        structuralGroup.addChild(newAccent)
        structuralGroup.addChild(newAccentGlow)
        structuralGroup.addChild(newTopBorder)
        structuralGroup.addChild(newBottomBorder)

        container.addChild(structuralGroup)

        // -- Build dimension content group above existing label content --
        let dimContentGroup = Entity()
        dimContentGroup.name = "dimension_content"

        // Position dimension text from top of new billboard downward
        var dimCursor = padding + (newTotalHeight - padding * 2)  // content area top

        // Check status banner (full-width colored strip above #NNN header)
        if let txtResult = bannerTextResult, let bgColor = bannerBgColor {
            let bannerH = txtResult.size.y + bannerPadV * 2
            // Full-width background strip
            let bannerW = newTotalWidth - padding * 0.5
            let bannerBgMesh = MeshResource.generateBox(
                size: [bannerW, bannerH, 0.0012],
                cornerRadius: bannerH * 0.2
            )
            var bannerMat = UnlitMaterial(color: bgColor)
            bannerMat.blending = .transparent(opacity: .init(floatLiteral: 0.85))
            let bannerBgEntity = ModelEntity(mesh: bannerBgMesh, materials: [bannerMat])
            // Center banner horizontally, position at top
            let bannerCenterY = dimCursor - bannerH / 2
            bannerBgEntity.position = SIMD3<Float>(0, bannerCenterY, 0.0003)
            dimContentGroup.addChild(bannerBgEntity)
            // Center text on banner
            let textY = dimCursor - bannerPadV - txtResult.size.y
            let textX = -txtResult.size.x / 2  // center-aligned
            txtResult.entity.position = SIMD3<Float>(textX, textY, 0.001)
            dimContentGroup.addChild(txtResult.entity)
            dimCursor -= bannerH + bannerGap
        }

        // #NNN header
        dimCursor -= idResult.size.y
        idResult.entity.position = SIMD3<Float>(newTextLeftX, dimCursor, 0)
        dimContentGroup.addChild(idResult.entity)

        // Separator after ID
        dimCursor -= sectionTopGap
        let idSepW = newMaxContentWidth
        let idSepMesh = MeshResource.generateBox(size: [idSepW, separatorThick, 0.0012])
        var idSepMat = UnlitMaterial(color: dimSeparatorColor)
        idSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let idSepEntity = ModelEntity(mesh: idSepMesh, materials: [idSepMat])
        idSepEntity.position = SIMD3<Float>(newTextLeftX + idSepW / 2, dimCursor, 0.0005)
        dimContentGroup.addChild(idSepEntity)
        dimCursor -= separatorThick + separatorMargin

        // DIMENSIONS section header
        dimCursor -= dimHeader.size.y
        dimHeader.entity.position = SIMD3<Float>(newTextLeftX, dimCursor, 0)
        dimContentGroup.addChild(dimHeader.entity)

        // Dimension data lines
        var newRevealEntities: [Entity] = []
        for pair in dimLinePairs {
            dimCursor -= lineGap
            let h = max(pair.label.size.y, pair.value.size.y)
            dimCursor -= h

            let lineContainer = Entity()
            pair.label.entity.position = SIMD3<Float>(newTextLeftX, dimCursor, 0)
            pair.value.entity.position = SIMD3<Float>(newValueLeftX, dimCursor, 0)
            lineContainer.addChild(pair.label.entity)
            lineContainer.addChild(pair.value.entity)
            lineContainer.scale = .zero  // Hidden for staggered reveal
            dimContentGroup.addChild(lineContainer)
            newRevealEntities.append(lineContainer)
        }

        // Thick separator between dimensions and label sections
        dimCursor -= thickSepGap
        let thickSepW = newMaxContentWidth
        let thickSepMesh = MeshResource.generateBox(size: [thickSepW, thickSeparatorThick, 0.0012])
        var thickSepMat = UnlitMaterial(color: dimAccent.withAlphaComponent(0.40))
        thickSepMat.blending = .transparent(opacity: .init(floatLiteral: 0.40))
        let thickSepEntity = ModelEntity(mesh: thickSepMesh, materials: [thickSepMat])
        thickSepEntity.position = SIMD3<Float>(newTextLeftX + thickSepW / 2, dimCursor, 0.0005)
        dimContentGroup.addChild(thickSepEntity)

        // Start dimension content hidden
        dimContentGroup.scale = .zero
        container.addChild(dimContentGroup)

        // Update reveal entities to dimension lines only (label lines already visible)
        revealEntities = newRevealEntities

        // -- Action icon row (unified actions) --
        let row = ActionIconBuilder.createActionRow(actions: ActionIconBuilder.labelUnifiedActions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        container.addChild(row)
        actionIconRow = row

        // Update stored metrics
        currentTotalHeight = newTotalHeight
        currentTotalWidth = newTotalWidth
        currentMaxContentWidth = newMaxContentWidth
        currentMaxLabelWidth = newMaxLabelWidth

        // -- Animate: structural entities grow, then dimension content fades in --
        let growDuration = PMTheme.labelBillboardExpandDuration
        let growStart = Date()

        let growTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(growStart)
            let t = Float(min(elapsed / growDuration, 1.0))
            let eased = 1.0 - pow(1.0 - t, 3)  // easeOutCubic

            // Grow dimension content from zero to full
            dimContentGroup.scale = SIMD3<Float>(repeating: eased)

            if t >= 1.0 {
                timer.invalidate()
                dimContentGroup.scale = .one

                // Stagger-reveal dimension text lines
                self.revealTextLines(completion: completion)
            }
        }
        RunLoop.main.add(growTimer, forMode: .common)
    }

    // MARK: - Action Icon Updates

    /// Replace the action icon row with new actions
    func updateActionIcons(_ actions: [ActionIconConfig]) {
        actionIconRow?.removeFromParent()
        actionIconRow = nil

        guard let container = containerEntity else { return }

        let row = ActionIconBuilder.createActionRow(actions: actions)
        row.position = SIMD3<Float>(0, -0.005, 0)
        container.addChild(row)
        actionIconRow = row
    }

    // MARK: - World Position

    /// Returns the world position of this billboard for callout targeting
    func getWorldPosition() -> SIMD3<Float> {
        return entity.position(relativeTo: nil)
    }

    /// Returns the world position of the billboard top, used as callout transition target
    /// so the 2D callout flies toward where dimensions will appear.
    func getTopWorldPosition() -> SIMD3<Float> {
        let base = entity.position(relativeTo: nil)
        return SIMD3<Float>(base.x, base.y + currentTotalHeight, base.z)
    }

    // MARK: - Dismiss

    /// Shrink billboard to zero and call completion
    func dismiss(completion: @escaping () -> Void) {
        let duration: Double = 0.3
        let startTime = Date()
        let startScale = entity.scale

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            let elapsed = Date().timeIntervalSince(startTime)
            let t = Float(min(elapsed / duration, 1.0))
            let eased = 1.0 - pow(1.0 - t, 3)

            self.entity.scale = startScale * (1.0 - eased)

            if t >= 1.0 {
                timer.invalidate()
                self.entity.isEnabled = false
                completion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Visibility

    func setVisible(_ visible: Bool) {
        entity.isEnabled = visible
    }
}
