//
//  HandleType.swift
//  SnapMeasure
//

import UIKit
import simd

/// Represents different types of handles for bounding box manipulation
enum HandleType: Int, CaseIterable {
    // Corner handles (0-7) - diagonal resize on 3 axes
    case corner0 = 0
    case corner1 = 1
    case corner2 = 2
    case corner3 = 3
    case corner4 = 4
    case corner5 = 5
    case corner6 = 6
    case corner7 = 7

    // Face handles (8-13) - single axis resize
    case faceNegX = 8  // -X face
    case facePosX = 9  // +X face
    case faceNegY = 10 // -Y face
    case facePosY = 11 // +Y face
    case faceNegZ = 12 // -Z face
    case facePosZ = 13 // +Z face

    /// Total number of handles
    static var count: Int { 14 }

    /// Whether this handle is a corner handle
    var isCorner: Bool {
        rawValue < 8
    }

    /// Whether this handle is a face handle
    var isFace: Bool {
        rawValue >= 8
    }

    /// The color for this handle type (white for Apple-style appearance)
    var color: UIColor {
        return UIColor(white: 1.0, alpha: 0.85)
    }

    /// The axis index for face handles (0=X, 1=Y, 2=Z), nil for corners
    var axisIndex: Int? {
        switch self {
        case .faceNegX, .facePosX: return 0
        case .faceNegY, .facePosY: return 1
        case .faceNegZ, .facePosZ: return 2
        default: return nil
        }
    }

    /// The direction multiplier for face handles (+1 or -1), nil for corners
    var faceDirection: Float? {
        switch self {
        case .faceNegX, .faceNegY, .faceNegZ: return -1
        case .facePosX, .facePosY, .facePosZ: return 1
        default: return nil
        }
    }

    /// The local position multiplier for corners (-1 or +1 for each axis)
    var cornerMultiplier: SIMD3<Float>? {
        switch self {
        case .corner0: return SIMD3<Float>(-1, -1, -1)
        case .corner1: return SIMD3<Float>( 1, -1, -1)
        case .corner2: return SIMD3<Float>( 1,  1, -1)
        case .corner3: return SIMD3<Float>(-1,  1, -1)
        case .corner4: return SIMD3<Float>(-1, -1,  1)
        case .corner5: return SIMD3<Float>( 1, -1,  1)
        case .corner6: return SIMD3<Float>( 1,  1,  1)
        case .corner7: return SIMD3<Float>(-1,  1,  1)
        default: return nil
        }
    }

    /// The opposite corner index (for corner handles)
    var oppositeCornerIndex: Int? {
        switch self {
        case .corner0: return 6  // (-1,-1,-1) opposite to (1,1,1)
        case .corner1: return 7  // (1,-1,-1) opposite to (-1,1,1)
        case .corner2: return 4  // (1,1,-1) opposite to (-1,-1,1)
        case .corner3: return 5  // (-1,1,-1) opposite to (1,-1,1)
        case .corner4: return 2  // (-1,-1,1) opposite to (1,1,-1)
        case .corner5: return 3  // (1,-1,1) opposite to (-1,1,-1)
        case .corner6: return 0  // (1,1,1) opposite to (-1,-1,-1)
        case .corner7: return 1  // (-1,1,1) opposite to (1,-1,-1)
        default: return nil
        }
    }

    /// Create from handle name (e.g., "handle_5")
    static func from(name: String) -> HandleType? {
        guard name.hasPrefix("handle_"),
              let index = Int(name.dropFirst(7)),
              index >= 0 && index < 14 else {
            return nil
        }
        return HandleType(rawValue: index)
    }

    /// The entity name for this handle
    var entityName: String {
        "handle_\(rawValue)"
    }

    /// Get the local position of this handle relative to box center
    /// - Parameter extents: The half-extents of the bounding box
    /// - Returns: Local position in box space
    func localPosition(extents: SIMD3<Float>) -> SIMD3<Float> {
        if let multiplier = cornerMultiplier {
            return multiplier * extents
        }

        // Horizontal handles (X/Z) are at the midpoints of top face edges
        // Vertical handles (Y) are at the centers of top and bottom faces
        switch self {
        case .faceNegX: return SIMD3<Float>(-extents.x, extents.y, 0)  // Top edge -X
        case .facePosX: return SIMD3<Float>( extents.x, extents.y, 0)  // Top edge +X
        case .faceNegY: return SIMD3<Float>(0, -extents.y, 0)          // Bottom face center
        case .facePosY: return SIMD3<Float>(0,  extents.y, 0)          // Top face center
        case .faceNegZ: return SIMD3<Float>(0, extents.y, -extents.z)  // Top edge -Z
        case .facePosZ: return SIMD3<Float>(0, extents.y,  extents.z)  // Top edge +Z
        default: return .zero
        }
    }

    /// Get the center position of the face for this face handle
    /// - Parameter extents: The half-extents of the bounding box
    /// - Returns: Local position of face center in box space
    func faceCenterPosition(extents: SIMD3<Float>) -> SIMD3<Float>? {
        switch self {
        case .faceNegX: return SIMD3<Float>(-extents.x, 0, 0)
        case .facePosX: return SIMD3<Float>( extents.x, 0, 0)
        case .faceNegY: return SIMD3<Float>(0, -extents.y, 0)
        case .facePosY: return SIMD3<Float>(0,  extents.y, 0)
        case .faceNegZ: return SIMD3<Float>(0, 0, -extents.z)
        case .facePosZ: return SIMD3<Float>(0, 0,  extents.z)
        default: return nil
        }
    }
}
