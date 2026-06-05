//
//  ScanningTipsView.swift
//  SnapMeasure
//

import SwiftUI

struct ScanningTipsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var generalExpanded = true
    @State private var twoTapExpanded = false
    @State private var avoidExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Section 1: General Scanning Tips
                    DisclosureGroup(isExpanded: $generalExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "iphone.radiowaves.left.and.right",
                                title: "tip.general.angle.title",
                                description: "tip.general.angle.desc"
                            )
                            TipRow(
                                icon: "ruler",
                                title: "tip.general.distance.title",
                                description: "tip.general.distance.desc"
                            )
                            TipRow(
                                icon: "hand.raised",
                                title: "tip.general.steady.title",
                                description: "tip.general.steady.desc"
                            )
                            TipRow(
                                icon: "arrow.up.to.line",
                                title: "tip.general.face.title",
                                description: "tip.general.face.desc"
                            )
                            TipRow(
                                icon: "exclamationmark.triangle",
                                title: "tip.general.steep.title",
                                description: "tip.general.steep.desc"
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text("tip.section.general")
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Section 2: Two-Tap Strategy
                    DisclosureGroup(isExpanded: $twoTapExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "1.circle",
                                title: "tip.twotap.first.title",
                                description: "tip.twotap.first.desc"
                            )
                            TipRow(
                                icon: "2.circle",
                                title: "tip.twotap.second.title",
                                description: "tip.twotap.second.desc"
                            )
                            TipRow(
                                icon: "angle",
                                title: "tip.twotap.sameangle.title",
                                description: "tip.twotap.sameangle.desc"
                            )
                            TipRow(
                                icon: "arrow.left.and.right",
                                title: "tip.twotap.samedist.title",
                                description: "tip.twotap.samedist.desc"
                            )
                            TipRow(
                                icon: "square.on.square",
                                title: "tip.twotap.overlap.title",
                                description: "tip.twotap.overlap.desc"
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text("tip.section.twotap")
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Section 3: What to Avoid
                    DisclosureGroup(isExpanded: $avoidExpanded) {
                        VStack(spacing: 12) {
                            TipRow(
                                icon: "arrow.2.squarepath",
                                title: "tip.avoid.sameangle.title",
                                description: "tip.avoid.sameangle.desc"
                            )
                            TipRow(
                                icon: "arrow.left.arrow.right",
                                title: "tip.avoid.opposite.title",
                                description: "tip.avoid.opposite.desc"
                            )
                            TipRow(
                                icon: "arrow.down.to.line",
                                title: "tip.avoid.above.title",
                                description: "tip.avoid.above.desc"
                            )
                            TipRow(
                                icon: "figure.walk",
                                title: "tip.avoid.moving.title",
                                description: "tip.avoid.moving.desc"
                            )
                            TipRow(
                                icon: "eye.slash",
                                title: "tip.avoid.surface.title",
                                description: "tip.avoid.surface.desc"
                            )
                            TipRow(
                                icon: "scope",
                                title: "tip.avoid.distance.title",
                                description: "tip.avoid.distance.desc"
                            )
                        }
                        .padding(.top, 8)
                    } label: {
                        Label {
                            Text("tip.section.avoid")
                                .font(PMTheme.mono(13, weight: .bold))
                        } icon: {
                            Image(systemName: "xmark.shield")
                                .foregroundColor(PMTheme.cyan)
                        }
                    }
                    .tint(PMTheme.cyan)
                    .padding()
                    .background(PMTheme.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .background(PMTheme.surfaceDark)
            .navigationTitle("tip.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(PMTheme.textSecondary)
                    }
                }
            }
        }
    }
}

/// Tip entry: icon + title + body. Originally defined in `SettingsView.swift`
/// (which we excluded when porting ProductMeasure into ShelfScout), so it now
/// lives next to its sole consumer.
struct TipRow: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(PMTheme.cyan)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PMTheme.mono(13, weight: .medium))
                Text(description)
                    .font(PMTheme.mono(11))
                    .foregroundColor(PMTheme.textSecondary)
            }
        }
    }
}
