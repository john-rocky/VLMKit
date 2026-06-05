//
//  DimensionCalloutView.swift
//  SnapMeasure
//

import SwiftUI

/// 2D overlay that shows dimension values sliding in from the right,
/// then transitions toward the 3D billboard position before fading out.
struct DimensionCalloutView: View {
    let boxId: Int
    let width: String
    let height: String
    let length: String
    let lineRevealed: [Bool]         // [id, W, H, L]
    let transitionProgress: CGFloat  // 0 = top-right, 1 = at billboard target
    let targetPosition: CGPoint
    let screenSize: CGSize
    /// VLMKit-generated description of the measured object. Rendered under the
    /// L line once available, independent of the line-reveal animation.
    var description: String? = nil
    /// Whether the VLM call is still in flight. Drives the "Describing…" row.
    var isDescribing: Bool = false

    private var accentColor: Color { PMTheme.cyan }

    private let cardWidth: CGFloat = 160

    // Right-side resting position (below top bar + toggle)
    private var restPosition: CGPoint {
        CGPoint(x: screenSize.width - cardWidth / 2 - 20, y: screenSize.height * 0.35)
    }

    private var interpolatedPosition: CGPoint {
        let t = transitionProgress
        return CGPoint(
            x: restPosition.x + (targetPosition.x - restPosition.x) * t,
            y: restPosition.y + (targetPosition.y - restPosition.y) * t
        )
    }

    private var currentScale: CGFloat {
        1.0 - 0.5 * transitionProgress
    }

    private var currentOpacity: CGFloat {
        1.0 - transitionProgress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lineRevealed.count > 0, lineRevealed[0] {
                calloutLine(text: String(format: "#%03d", boxId), isAccent: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if lineRevealed.count > 1, lineRevealed[1] {
                calloutLine(text: "W  \(width)")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if lineRevealed.count > 2, lineRevealed[2] {
                calloutLine(text: "H  \(height)")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if lineRevealed.count > 3, lineRevealed[3] {
                calloutLine(text: "L  \(length)")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            // VLM object description (and its in-flight indicator). Appears
            // when the model lands a result, independent of the W/H/L reveal.
            if isDescribing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(accentColor)
                    Text("Describing…")
                        .font(PMTheme.mono(PMTheme.calloutBodyFontSize - 1, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
            if let desc = description, !desc.isEmpty {
                Text(desc)
                    .font(PMTheme.mono(PMTheme.calloutBodyFontSize - 1, weight: .regular))
                    .foregroundColor(PMTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: description)
        .animation(.easeOut(duration: 0.2), value: isDescribing)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3)
                Spacer()
            }
            .background(PMTheme.surfaceGlass)
        )
        .clipShape(RoundedRectangle(cornerRadius: PMTheme.calloutCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PMTheme.calloutCornerRadius)
                .strokeBorder(accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .frame(width: cardWidth)
        .scaleEffect(currentScale)
        .position(interpolatedPosition)
        .opacity(currentOpacity)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func calloutLine(text: String, isAccent: Bool = false) -> some View {
        Text(text)
            .font(PMTheme.mono(isAccent ? PMTheme.calloutIdFontSize : PMTheme.calloutBodyFontSize, weight: isAccent ? .bold : .medium))
            .foregroundColor(isAccent ? accentColor : PMTheme.textPrimary)
    }
}
