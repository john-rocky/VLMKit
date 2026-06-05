//
//  LabelScanBracketsView.swift
//  SnapMeasure
//

import SwiftUI

/// Blue corner brackets overlay for label scanning mode.
/// Same layout as CornerBracketsView but with neon blue color and slightly smaller target area.
struct LabelScanBracketsView: View {
    let phase: BoundingBoxAnimationPhase
    let screenSize: CGSize

    private let bracketColor: Color = PMTheme.labelBlue
    private let bracketLineWidth: CGFloat = 3
    private let bracketLength: CGFloat = 20
    private let targetInset: CGFloat = 80  // Slightly smaller than box brackets (60)

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8
    @State private var diamondRotation: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let targetSize = CGSize(
                width: geometry.size.width - targetInset * 2,
                height: geometry.size.width - targetInset * 2
            )

            ZStack {
                if phase == .showingTargetBrackets {
                    // Crosshair
                    crosshairView(center: center)

                    // Outer dim brackets
                    targetBracketsView(center: center, size: targetSize, opacity: 0.3, offset: 4)

                    // Inner bright brackets (pulsing)
                    targetBracketsView(center: center, size: targetSize, opacity: pulseOpacity, offset: 0)
                        .scaleEffect(pulseScale, anchor: .center)

                    // Rotating center diamond
                    Diamond()
                        .stroke(bracketColor.opacity(0.30), lineWidth: 1)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(diamondRotation))
                        .position(x: center.x, y: center.y)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: phase)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.04
                pulseOpacity = 1.0
            }
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                diamondRotation = 360
            }
        }
    }

    // MARK: - Crosshair

    @ViewBuilder
    private func crosshairView(center: CGPoint) -> some View {
        let crossSize: CGFloat = 40
        let dotSize: CGFloat = 4

        ZStack {
            Rectangle()
                .fill(bracketColor.opacity(0.40))
                .frame(width: crossSize, height: 1)
                .position(x: center.x, y: center.y)

            Rectangle()
                .fill(bracketColor.opacity(0.40))
                .frame(width: 1, height: crossSize)
                .position(x: center.x, y: center.y)

            Circle()
                .fill(bracketColor.opacity(0.40))
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
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .topRight, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y - halfHeight)

            BracketShape(corner: .bottomLeft, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x - halfWidth, y: center.y + halfHeight)

            BracketShape(corner: .bottomRight, length: bracketLength)
                .stroke(bracketColor.opacity(opacity), lineWidth: bracketLineWidth)
                .frame(width: bracketLength, height: bracketLength)
                .position(x: center.x + halfWidth, y: center.y + halfHeight)
        }
    }
}
