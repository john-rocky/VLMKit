//
//  StatusVignetteView.swift
//  SnapMeasure
//

import SwiftUI
import UIKit

/// Full-screen radial gradient vignette that flashes green (OK) or red (NG)
/// around the screen edges when measurement status is revealed.
/// Also displays a large flashing "CHECK OK" / "CHECK REQUIRED" label.
struct StatusVignetteView: View {
    let isNG: Bool
    @Binding var isVisible: Bool

    @State private var opacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var textScale: CGFloat = 0.7

    private var vignetteColor: Color {
        isNG ? PMTheme.red : PMTheme.cyan
    }

    private var statusText: String { "\u{2713}" }

    private var statusIcon: String { "" }

    var body: some View {
        ZStack {
            // Thick edge band — high opacity at screen border
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.35),
                    .init(color: vignetteColor.opacity(0.30), location: 0.6),
                    .init(color: vignetteColor.opacity(0.65), location: 0.85),
                    .init(color: vignetteColor.opacity(0.85), location: 1.0),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: UIScreen.main.bounds.height * 0.6
            )
            .opacity(opacity)

            // Corner intensifiers — extra glow in corners
            Rectangle()
                .fill(vignetteColor.opacity(0.25))
                .mask(
                    LinearGradient(
                        colors: [vignetteColor, .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .opacity(opacity)

            Rectangle()
                .fill(vignetteColor.opacity(0.25))
                .mask(
                    LinearGradient(
                        colors: [vignetteColor, .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                )
                .opacity(opacity)

            // Large flashing status text
            VStack(spacing: 8) {
                Text(statusIcon)
                    .font(.system(size: 48))
                Text(statusText)
                    .font(.system(size: 28, weight: .heavy, design: .monospaced))
                    .tracking(2)
            }
            .foregroundColor(vignetteColor)
            .shadow(color: vignetteColor.opacity(0.8), radius: 20)
            .shadow(color: vignetteColor.opacity(0.4), radius: 40)
            .opacity(textOpacity)
            .scaleEffect(textScale)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            if isNG {
                runDoublePulse()
            } else {
                runSinglePulse()
            }
        }
    }

    private func runSinglePulse() {
        // Vignette
        withAnimation(.easeIn(duration: 0.2)) {
            opacity = 1.0
        }
        // Text pops in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            textOpacity = 1.0
            textScale = 1.0
        }
        // Fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 0
                textOpacity = 0
                textScale = 0.9
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isVisible = false
        }
    }

    private func runDoublePulse() {
        // First pulse
        withAnimation(.easeIn(duration: 0.15)) {
            opacity = 1.0
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
            textOpacity = 1.0
            textScale = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.2)) {
                opacity = 0.1
                textOpacity = 0.2
                textScale = 0.95
            }
        }
        // Second pulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeIn(duration: 0.15)) {
                opacity = 1.0
                textOpacity = 1.0
                textScale = 1.05
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 1.2)) {
                opacity = 0
                textOpacity = 0
                textScale = 0.9
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            isVisible = false
        }
    }
}
