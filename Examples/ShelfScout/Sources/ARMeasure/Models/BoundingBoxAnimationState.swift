//
//  BoundingBoxAnimationState.swift
//  SnapMeasure
//

import Foundation
import CoreGraphics
import simd

/// Animation phases for the bounding box appearance animation
enum BoundingBoxAnimationPhase: Equatable {
    /// Showing 2D target brackets - waiting for user tap
    case showingTargetBrackets

    /// Edge trace: bottom edges draw sequentially with corner markers
    case edgeTrace

    /// 3D rect flying from camera position to object bottom plane
    case flyingToBottom

    /// Growing vertically from the bottom plane
    case growingVertical

    /// Completion pulse flash
    case completionPulse

    /// 2D dimension callout card sliding in from top-right
    case dimensionCallout

    /// 2D callout transitioning to 3D billboard
    case calloutTransition

    /// Animation complete - box is fully visible
    case complete
}

/// Context information for the bounding box animation after tap
struct BoundingBoxAnimationContext {
    /// Tap point in screen coordinates
    let tapPoint: CGPoint

    /// Target bounding box in 3D world space
    let targetBox: BoundingBox3D

    /// Bottom plane corners projected to screen coordinates
    let bottomCorners: [CGPoint]

    /// Screen size for calculations
    let screenSize: CGSize

    /// Target rectangle size (from projected bottom corners)
    var targetRectSize: CGSize {
        guard bottomCorners.count == 4 else { return CGSize(width: 100, height: 100) }

        let minX = bottomCorners.map { $0.x }.min() ?? 0
        let maxX = bottomCorners.map { $0.x }.max() ?? 100
        let minY = bottomCorners.map { $0.y }.min() ?? 0
        let maxY = bottomCorners.map { $0.y }.max() ?? 100

        return CGSize(width: maxX - minX, height: maxY - minY)
    }

    /// Center of the target rectangle in screen coordinates
    var targetRectCenter: CGPoint {
        guard bottomCorners.count == 4 else { return tapPoint }

        let avgX = bottomCorners.map { $0.x }.reduce(0, +) / 4
        let avgY = bottomCorners.map { $0.y }.reduce(0, +) / 4

        return CGPoint(x: avgX, y: avgY)
    }
}

/// Animation timing constants
struct BoxAnimationTiming {
    /// Duration for edge trace (bottom edges drawing sequentially)
    static let edgeTrace: Double = PMTheme.edgeTraceDuration

    /// Duration for 3D rect to fly from camera to bottom plane
    static let flyToBottom: Double = PMTheme.flyToBottomDuration

    /// Duration for vertical edges to grow
    static let growVertical: Double = PMTheme.growVerticalDuration

    /// Duration for completion pulse flash
    static let completionPulse: Double = PMTheme.completionPulseDuration

    /// Duration for dimension callout slide-in
    static let dimensionCallout: Double = PMTheme.calloutLineStagger * 4 + PMTheme.calloutHoldDuration

    /// Duration for callout-to-billboard transition
    static let calloutTransition: Double = PMTheme.calloutTransitionDuration

    /// Total animation duration
    static let total: Double = edgeTrace + flyToBottom + growVertical + completionPulse + dimensionCallout + calloutTransition
}
