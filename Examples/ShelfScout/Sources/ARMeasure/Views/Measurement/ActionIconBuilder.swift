//
//  ActionIconBuilder.swift
//  SnapMeasure
//

import RealityKit
import UIKit

/// Action types for 3D pill-shaped action icons
enum ActionType: String, CaseIterable {
    case save = "action_save"
    case edit = "action_edit"
    case discard = "action_discard"
    case done = "action_done"
    case fit = "action_fit"
    case cancel = "action_cancel"
    case reEdit = "action_reedit"
    case delete = "action_delete"
    case refine = "action_refine"
    case labelDone = "action_label_done"
    case labelRescan = "action_label_rescan"
}

/// Configuration for a single action icon
struct ActionIconConfig {
    let type: ActionType
    let sfSymbol: String
    let color: UIColor
}

/// Utility for building 3D pill-shaped action icon rows with SF Symbol icons
enum ActionIconBuilder {
    // MARK: - Presets

    /// Actions for active box in normal mode: Discard, Refine, Edit, Save
    static let activeNormalActions: [ActionIconConfig] = [
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .refine, sfSymbol: "arrow.triangle.2.circlepath", color: PMTheme.uiCyan),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for active box when refinement limit reached: Discard, Edit, Save
    static let activeNormalActionsNoRefine: [ActionIconConfig] = [
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for refining mode: Cancel only
    static let activeRefiningActions: [ActionIconConfig] = [
        ActionIconConfig(type: .cancel, sfSymbol: "xmark", color: PMTheme.uiRed),
    ]

    /// Actions for active box in editing mode: Cancel, Fit, Done
    static let activeEditActions: [ActionIconConfig] = [
        ActionIconConfig(type: .cancel, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .fit, sfSymbol: "square.resize", color: PMTheme.uiBlue),
        ActionIconConfig(type: .done, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for label billboard: Rescan only (Done removed — next tap advances workflow)
    static let labelBillboardActions: [ActionIconConfig] = [
        ActionIconConfig(type: .labelRescan, sfSymbol: "arrow.counterclockwise", color: UIColor(hex: 0x00BFFF)),
    ]

    /// Actions for unified label billboard (after dimensions absorbed): same as normal box actions
    static let labelUnifiedActions: [ActionIconConfig] = [
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .refine, sfSymbol: "arrow.triangle.2.circlepath", color: PMTheme.uiCyan),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for unified label billboard when refinement limit reached
    static let labelUnifiedNoRefineActions: [ActionIconConfig] = [
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for warehouse unified billboard (box + label): Rescan, Discard, Refine, Edit, Save
    static let warehouseCombinedActions: [ActionIconConfig] = [
        ActionIconConfig(type: .labelRescan, sfSymbol: "arrow.counterclockwise", color: UIColor(hex: 0x00BFFF)),
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .refine, sfSymbol: "arrow.triangle.2.circlepath", color: PMTheme.uiCyan),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for warehouse unified billboard when refinement limit reached
    static let warehouseCombinedNoRefineActions: [ActionIconConfig] = [
        ActionIconConfig(type: .labelRescan, sfSymbol: "arrow.counterclockwise", color: UIColor(hex: 0x00BFFF)),
        ActionIconConfig(type: .discard, sfSymbol: "xmark", color: PMTheme.uiRed),
        ActionIconConfig(type: .edit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .save, sfSymbol: "checkmark", color: PMTheme.uiGreen),
    ]

    /// Actions for completed box: Re-edit, Delete
    static let completedActions: [ActionIconConfig] = [
        ActionIconConfig(type: .reEdit, sfSymbol: "pencil", color: PMTheme.uiAmber),
        ActionIconConfig(type: .delete, sfSymbol: "trash", color: PMTheme.uiRed),
    ]

    // MARK: - Constants

    private static let pillWidth: Float = 0.012
    private static let pillHeight: Float = 0.008
    private static let pillDepth: Float = 0.002
    private static let pillSpacing: Float = 0.004
    private static let iconSize: CGFloat = 24
    private static let collisionScale: Float = 1.5

    // MARK: - Public Methods

    /// Create a horizontal row of action icon pills
    static func createActionRow(actions: [ActionIconConfig]) -> Entity {
        let rowEntity = Entity()
        rowEntity.name = "action_row"

        let totalWidth = Float(actions.count) * pillWidth + Float(actions.count - 1) * pillSpacing
        let startX = -totalWidth / 2 + pillWidth / 2

        for (index, action) in actions.enumerated() {
            let pillEntity = createPill(config: action)
            let xPos = startX + Float(index) * (pillWidth + pillSpacing)
            pillEntity.position = SIMD3<Float>(xPos, 0, 0)
            rowEntity.addChild(pillEntity)
        }

        return rowEntity
    }

    /// Parse an entity name to determine the action type
    static func parseActionType(entityName: String) -> ActionType? {
        return ActionType(rawValue: entityName)
    }

    /// Check if an entity name belongs to an action icon
    static func isActionEntity(_ name: String) -> Bool {
        return name.hasPrefix("action_")
    }

    // MARK: - Private Methods

    private static func createPill(config: ActionIconConfig) -> Entity {
        let pillParent = Entity()
        pillParent.name = config.type.rawValue

        // Pill background (colored rounded box)
        let cornerRadius = min(pillWidth, pillHeight) * 0.4
        let bgMesh = MeshResource.generateBox(
            size: [pillWidth, pillHeight, pillDepth],
            cornerRadius: cornerRadius
        )
        var bgMaterial = UnlitMaterial(color: config.color)
        bgMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let bgEntity = ModelEntity(mesh: bgMesh, materials: [bgMaterial])
        bgEntity.name = config.type.rawValue
        pillParent.addChild(bgEntity)

        // SF Symbol icon rendered as texture
        if let textureResource = renderSFSymbolTexture(name: config.sfSymbol, size: iconSize) {
            let iconWidth: Float = 0.006
            let iconHeight: Float = 0.006
            let iconMesh = MeshResource.generatePlane(width: iconWidth, height: iconHeight)
            var iconMaterial = UnlitMaterial()
            iconMaterial.color = .init(tint: .white, texture: .init(textureResource))
            iconMaterial.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            let iconEntity = ModelEntity(mesh: iconMesh, materials: [iconMaterial])
            iconEntity.name = config.type.rawValue
            iconEntity.position = SIMD3<Float>(0, 0, pillDepth / 2 + 0.0003)
            pillParent.addChild(iconEntity)
        }

        // Collision component (enlarged hit area)
        let collisionShape = ShapeResource.generateBox(
            size: [pillWidth * collisionScale, pillHeight * collisionScale, pillDepth * 3]
        )
        pillParent.components[CollisionComponent.self] = CollisionComponent(shapes: [collisionShape])

        return pillParent
    }

    /// Render an SF Symbol into a TextureResource for use on a 3D plane
    private static func renderSFSymbolTexture(name: String, size: CGFloat) -> TextureResource? {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let symbolImage = UIImage(systemName: name, withConfiguration: config) else {
            return nil
        }

        let imageSize = CGSize(width: size * 2, height: size * 2)
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let renderedImage = renderer.image { context in
            // Clear background (transparent)
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: imageSize))

            // Draw symbol centered in white
            let tintedImage = symbolImage.withTintColor(.white, renderingMode: .alwaysOriginal)
            let symbolSize = tintedImage.size
            let origin = CGPoint(
                x: (imageSize.width - symbolSize.width) / 2,
                y: (imageSize.height - symbolSize.height) / 2
            )
            tintedImage.draw(at: origin)
        }

        guard let cgImage = renderedImage.cgImage else { return nil }

        return try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
    }
}
