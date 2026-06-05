//
//  TapIndicatorView.swift
//  SnapMeasure
//

import SwiftUI

/// Animated ring that appears at the tap position and pulses outward
struct TapIndicatorView: View {
    let position: CGPoint

    @State private var ringScale: CGFloat = 0.5
    @State private var ringOpacity: Double = 1.0
    @State private var dotScale: CGFloat = 1.2
    @State private var dotOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Expanding ring
            Circle()
                .strokeBorder(PMTheme.green.opacity(ringOpacity), lineWidth: 1.5)
                .frame(width: 40, height: 40)
                .scaleEffect(ringScale)

            // Center dot
            Circle()
                .fill(PMTheme.green.opacity(dotOpacity))
                .frame(width: 8, height: 8)
                .scaleEffect(dotScale)
        }
        .position(position)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                ringScale = 1.5
                ringOpacity = 0
            }
            withAnimation(.easeOut(duration: 0.15)) {
                dotScale = 1.0
            }
            withAnimation(.easeOut(duration: 1.2).delay(0.3)) {
                dotOpacity = 0
            }
        }
    }
}
