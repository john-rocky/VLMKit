//
//  Theme.swift
//  SnapMeasure
//
//  Centralized design tokens for the Dark Tech / Holographic Scanner theme
//

import SwiftUI
import UIKit

// MARK: - PMTheme (Design Tokens)

enum PMTheme {

    // MARK: Primary & Accents

    static let cyan       = Color(hex: 0x39FF14)
    static let green      = Color(hex: 0x00E680)
    static let amber      = Color(hex: 0xFFBF00)
    static let red        = Color(hex: 0xFF404D)
    static let blue       = Color(hex: 0x3380FF)

    static let uiCyan     = UIColor(hex: 0x39FF14)
    static let uiGreen    = UIColor(hex: 0x00E680)
    static let uiAmber    = UIColor(hex: 0xFFBF00)
    static let uiRed      = UIColor(hex: 0xFF404D)
    static let uiBlue     = UIColor(hex: 0x3380FF)

    // MARK: Label Reader (Neon Green)

    static let labelBlue       = Color(hex: 0x39FF14)
    static let uiLabelBlue     = UIColor(hex: 0x39FF14)
    static let uiLabelBlueGlow = UIColor(hex: 0x39FF14).withAlphaComponent(0.15)
    static let labelLiftDuration: Double = 2.0
    static let labelTypingStagger: Double = 0.12
    static let labelDismissDuration: Double = 0.3
    static let barcodeScanDuration: Double = 2.0
    static let barcodeScanDetectTime: Double = 1.2
    static let barcodeScanFadeTime: Double = 1.6
    static let labelBillboardTransitionDuration: Double = 0.8
    static let labelBillboardRevealStagger: Double = 0.10
    static let labelBillboardExpandDuration: Double = 0.4

    static var labelBlueGradient: LinearGradient {
        LinearGradient(
            colors: [labelBlue, labelBlue.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Surfaces

    static let surfaceDark     = Color(hex: 0x0F1219)
    static let surfaceCard     = Color(hex: 0x1A1C26)
    static let surfaceElevated = Color(hex: 0x242633)
    static let surfaceGlass    = Color(red: 13/255, green: 18/255, blue: 31/255).opacity(0.85)

    static let uiSurfaceDark   = UIColor(hex: 0x0F1219)
    static let uiSurfaceGlass  = UIColor(red: 13/255, green: 18/255, blue: 31/255, alpha: 0.85)

    // MARK: Text

    static let textPrimary   = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textDimmed    = Color.white.opacity(0.40)

    static let uiTextPrimary   = UIColor(white: 1.0, alpha: 0.95)
    static let uiTextSecondary = UIColor(white: 1.0, alpha: 0.60)

    // MARK: 3D Edge Dimensions

    static let innerEdgeRadius: Float = 0.0005   // 1.0mm diameter -> 0.5mm radius
    static let outerEdgeRadius: Float = 0.0015   // 3.0mm diameter -> 1.5mm radius
    static let cornerMarkerRadius: Float = 0.003 // 6mm diameter sphere
    static let cornerMarkerRadiusSmall: Float = 0.0025 // 5mm for completed

    // MARK: 3D Edge Colors

    /// Active box inner edge: bright cyan, full alpha
    static let uiEdgeInner  = UIColor(hex: 0x39FF14).withAlphaComponent(1.0)
    /// Active box outer glow edge: cyan, low alpha
    static let uiEdgeOuter  = UIColor(hex: 0x39FF14).withAlphaComponent(0.35)
    /// Corner marker: cyan sphere
    static let uiCornerMarker = UIColor(hex: 0x39FF14).withAlphaComponent(0.9)

    /// Completed box inner edge: same bright green, opaque to avoid transparent depth-sort issues
    static let uiEdgeInnerDim  = UIColor(hex: 0x39FF14)
    static let uiEdgeOuterDim  = UIColor(hex: 0x39FF14).withAlphaComponent(0.25)
    static let uiCornerMarkerDim = UIColor(hex: 0x39FF14).withAlphaComponent(0.6)

    /// Red wireframe colors (for check-required boxes)
    static let uiEdgeInnerRed = UIColor(hex: 0xFF404D).withAlphaComponent(1.0)
    static let uiEdgeOuterRed = UIColor(hex: 0xFF404D).withAlphaComponent(0.35)
    static let uiCornerMarkerRed = UIColor(hex: 0xFF404D).withAlphaComponent(0.6)

    // MARK: Shipping Box Wireframe (cyan-blue, distinct from neon green measurement wireframe)
    static let uiShippingBoxInner = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)
    static let uiShippingBoxOuter = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)

    // MARK: Billboard

    static let uiBillboardBg     = UIColor(red: 13/255, green: 18/255, blue: 31/255, alpha: 0.85)
    static let uiBillboardAccent = UIColor(hex: 0x39FF14)
    static let uiBillboardText   = UIColor(white: 1.0, alpha: 0.95)
    static let uiBillboardTopBorder = UIColor(hex: 0x39FF14).withAlphaComponent(0.40)

    // MARK: Completion Pulse

    static let uiPulseColor = UIColor(hex: 0x80FF57)

    // MARK: Animation Timing

    static let edgeTraceDuration: Double = 0.5
    static let flyToBottomDuration: Double = 0.4
    static let growVerticalDuration: Double = 0.4
    static let completionPulseDuration: Double = 0.3
    static let totalAnimationDuration: Double = 1.6

    // MARK: Dimension Callout

    static let calloutLineStagger: Double = 0.15
    static let calloutHoldDuration: Double = 0.20
    static let calloutTransitionDuration: Double = 0.50
    static let calloutCornerRadius: CGFloat = 12
    static let calloutIdFontSize: CGFloat = 16
    static let calloutBodyFontSize: CGFloat = 14

    // MARK: Reticle Target
    static let reticleDepthReadoutFontSize: CGFloat = 10
    static let reticleTargetTransitionDuration: Double = 0.2

    // MARK: Stability Feedback

    static func bracketInset(for level: StabilityLevel) -> CGFloat {
        switch level {
        case .moving:   return 70
        case .settling: return 56
        case .stable:   return 44
        case .locked:   return 34
        }
    }

    static func crosshairOpacity(for level: StabilityLevel) -> Double {
        switch level {
        case .moving:   return 0.30
        case .settling: return 0.50
        case .stable:   return 0.75
        case .locked:   return 1.0
        }
    }

    static func bracketLineWidth(for level: StabilityLevel) -> CGFloat {
        switch level {
        case .moving:   return 2.0
        case .settling: return 2.5
        case .stable:   return 3.0
        case .locked:   return 4.0
        }
    }

    static let stabilitySettleTransition: Double = 0.6
    static let stabilityLockSpringResponse: Double = 0.25
    static let stabilityLockedColor = Color(hex: 0x00E680)

    // MARK: Gradients

    static var cyanGradient: LinearGradient {
        LinearGradient(
            colors: [cyan, cyan.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var headerGradient: LinearGradient {
        LinearGradient(
            colors: [surfaceCard, surfaceDark],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Console

    static let consoleTypingStagger: Double = 0.08
    static let consoleHeaderFontSize: CGFloat = 16
    static let consoleFieldFontSize: CGFloat = 12
    static let consoleSectionFontSize: CGFloat = 11

    // MARK: Fonts

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Color Hex Initializer

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
