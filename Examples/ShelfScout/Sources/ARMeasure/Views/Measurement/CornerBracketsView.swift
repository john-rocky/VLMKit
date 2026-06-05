//
//  CornerBracketsView.swift
//  SnapMeasure
//

import SwiftUI

/// 2D corner brackets overlay - shown as targeting guide before tap
struct CornerBracketsView: View {
    let phase: BoundingBoxAnimationPhase
    let screenSize: CGSize
    var stabilityLevel: StabilityLevel = .moving
    var targetState: ReticleTargetState = .noTarget
    var centerDepth: Float = 0

    // Bracket styling
    private let bracketLength: CGFloat = 24

    private var currentInset: CGFloat { PMTheme.bracketInset(for: stabilityLevel) }
    private var currentLineWidth: CGFloat { PMTheme.bracketLineWidth(for: stabilityLevel) }

    private var currentCrosshairOpacity: Double {
        let base = PMTheme.crosshairOpacity(for: stabilityLevel)
        switch targetState {
        case .noTarget:       return base * 0.5
        case .targetDetected: return base * 0.85
        case .targetLocked:   return base
        }
    }

    private var currentColor: Color {
        let baseColor: Color
        switch stabilityLevel {
        case .moving:   baseColor = PMTheme.cyan.opacity(0.55)
        case .settling: baseColor = PMTheme.cyan.opacity(0.75)
        case .stable:   baseColor = PMTheme.cyan.opacity(0.95)
        case .locked:   baseColor = PMTheme.stabilityLockedColor
        }

        // Dim when no target
        if targetState == .noTarget {
            return baseColor.opacity(0.5)
        }
        // Green when locked on target + device stable
        if targetState == .targetLocked && stabilityLevel >= .stable {
            return PMTheme.stabilityLockedColor
        }
        return baseColor
    }

    private var isPulsing: Bool { stabilityLevel != .locked }

    /// Diamond rotation speed based on target state
    private var diamondRotationDuration: Double {
        switch targetState {
        case .noTarget:       return 8.0
        case .targetDetected: return 4.0
        case .targetLocked:   return 0   // stopped
        }
    }

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8
    @State private var diamondRotation: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let targetSize = CGSize(
                width: geometry.size.width - currentInset * 2,
                height: geometry.size.width - currentInset * 2
            )

            ZStack {
                if phase == .showingTargetBrackets {
                    // Scanning crosshair (center)
                    crosshairView(center: center)

                    // Outer dim brackets (offset)
                    targetBracketsView(center: center, size: targetSize, opacity: 0.3, offset: 4)

                    // Inner bright brackets (pulsing when not locked)
                    targetBracketsView(center: center, size: targetSize, opacity: isPulsing ? pulseOpacity : 1.0, offset: 0)
                        .scaleEffect(isPulsing ? pulseScale : 1.0, anchor: .center)

                    // Rotating center diamond (stops + scales up when locked)
                    Diamond()
                        .stroke(currentColor.opacity(0.30), lineWidth: 1)
                        .frame(width: 10, height: 10)
                        .scaleEffect(targetState == .targetLocked ? 1.3 : 1.0)
                        .rotationEffect(.degrees(diamondRotation))
                        .position(x: center.x, y: center.y)

                    // Depth readout below crosshair (visible when target locked)
                    if targetState == .targetLocked && centerDepth > 0 {
                        Text(String(format: "%.2fm", centerDepth))
                            .font(PMTheme.mono(PMTheme.reticleDepthReadoutFontSize))
                            .foregroundColor(currentColor.opacity(0.7))
                            .position(x: center.x, y: center.y + 28)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: phase)
        .animation(
            stabilityLevel == .locked
                ? .spring(response: PMTheme.stabilityLockSpringResponse, dampingFraction: 0.7)
                : .easeInOut(duration: PMTheme.stabilitySettleTransition),
            value: stabilityLevel
        )
        .animation(.easeInOut(duration: PMTheme.reticleTargetTransitionDuration), value: targetState)
        .allowsHitTesting(false)
        .onAppear {
            startPulseAnimation()
            startDiamondRotation()
        }
        .onChange(of: targetState) { _, newState in
            // Restart diamond rotation when target state changes
            startDiamondRotation()
        }
        .onChange(of: stabilityLevel) { _, newLevel in
            if newLevel == .locked {
                // Snap animation: spring for the "squeeze" feel
                withAnimation(.spring(response: PMTheme.stabilityLockSpringResponse, dampingFraction: 0.7)) {
                    pulseScale = 1.0
                    pulseOpacity = 1.0
                }
            } else if newLevel == .moving {
                // Resume pulse animation
                startPulseAnimation()
            } else {
                // Settling/stable: smooth ease transition
                withAnimation(.easeInOut(duration: PMTheme.stabilitySettleTransition)) {
                    // Keep pulse running, just let inset/color change via computed properties
                }
            }
        }
    }

    private func startDiamondRotation() {
        let duration = diamondRotationDuration
        if duration > 0 {
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                diamondRotation += 360
            }
        }
        // When targetLocked (duration == 0), animation naturally stops at current rotation
    }

    private func startPulseAnimation() {
        pulseScale = 1.0
        pulseOpacity = 0.8
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulseScale = 1.04
            pulseOpacity = 1.0
        }
    }

    // MARK: - Crosshair

    @ViewBuilder
    private func crosshairView(center: CGPoint) -> some View {
        let crossSize: CGFloat = 40
        let dotSize: CGFloat = 4

        ZStack {
            // Horizontal line
            Rectangle()
                .fill(currentColor.opacity(currentCrosshairOpacity))
                .frame(width: crossSize, height: 1)
                .position(x: center.x, y: center.y)

            // Vertical line
            Rectangle()
                .fill(currentColor.opacity(currentCrosshairOpacity))
                .frame(width: 1, height: crossSize)
                .position(x: center.x, y: center.y)

            // Center dot
            Circle()
                .fill(currentColor.opacity(currentCrosshairOpacity))
                .frame(width: dotSize, height: dotSize)
                .position(x: center.x, y: center.y)
        }
    }

    // MARK: - Target Brackets

    @ViewBuilder
    private func targetBracketsView(center: CGPoint, size: CGSize, opacity: Double, offset: CGFloat) -> some View {
        let halfWidth = size.width / 2 + offset
        let halfHeight = size.height / 2 + offset

        ZStack {
            BracketShape(corner: .topLeft, length: bracketLength)
                .stroke(currentColor.opacity(opacity), lineWidth: currentLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .topRight, length: bracketLength)
                .stroke(currentColor.opacity(opacity), lineWidth: currentLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .bottomLeft, length: bracketLength)
                .stroke(currentColor.opacity(opacity), lineWidth: currentLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y + halfHeight)

            BracketShape(corner: .bottomRight, length: bracketLength)
                .stroke(currentColor.opacity(opacity), lineWidth: currentLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y + halfHeight)
        }
    }
}

// MARK: - Bracket Shape

enum BracketCorner {
    case topLeft, topRight, bottomLeft, bottomRight
}

struct BracketShape: Shape {
    let corner: BracketCorner
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        switch corner {
        case .topLeft:
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: length))

        case .topRight:
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width - length, y: 0))
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: length))

        case .bottomLeft:
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: length, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: 0, y: rect.height - length))

        case .bottomRight:
            path.move(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width - length, y: rect.height))
            path.move(to: CGPoint(x: rect.width, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height - length))
        }

        return path
    }
}

// MARK: - Diamond Shape

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        CornerBracketsView(
            phase: .showingTargetBrackets,
            screenSize: CGSize(width: 400, height: 800),
            stabilityLevel: .locked,
            targetState: .targetLocked,
            centerDepth: 0.72
        )
    }
}
