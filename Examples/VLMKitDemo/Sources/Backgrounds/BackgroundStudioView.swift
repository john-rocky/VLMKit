import SwiftUI
import VLMKit

/// Modal sheet hosting `BackgroundStudio`. Mode pills at top (only ones whose
/// `isAvailable` is true), candidate grid in the middle, Apply / Cancel at the
/// bottom. Tapping a candidate selects it; Apply calls back with the chosen
/// UIImage so the parent can store it as the listing's hero image.
struct BackgroundStudioView: View {
    let sourceImage: UIImage
    let vlmImage: VLMImage
    let runner: VLMRunner
    let onApply: (UIImage) -> Void

    @StateObject private var studio = BackgroundStudio()
    @State private var pickedIndex: Int?
    /// Set when the user taps a disabled mode pill — shown as a small alert
    /// so they can see why the tab is grayed out (e.g. "Sideload HyperSD
    /// models — see README"). `.help()` doesn't render on iOS, so we need
    /// an explicit gesture path.
    @State private var unavailableHint: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                modePills
                if studio.selectedMode == .diffusion { diffusionNotice }
                Divider()
                content
                if case .ready(let candidates) = studio.phase, !candidates.isEmpty {
                    applyBar(candidates: candidates)
                }
            }
            .padding()
            .navigationTitle("Background Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await studio.run(on: sourceImage, runner: runner, vlmImage: vlmImage)
        }
        .onChange(of: studio.selectedMode) { _, newMode in
            pickedIndex = nil
            Task { await studio.switchMode(to: newMode) }
        }
        // Free HyperSD's ~2 GB of weights and clear the cached suggestions
        // when the sheet closes. The VLM stays unloaded until the next
        // recipe call cold-loads it (paid for at that point).
        .onDisappear { studio.reset() }
        .alert(
            "Mode unavailable",
            isPresented: Binding(
                get: { unavailableHint != nil },
                set: { if !$0 { unavailableHint = nil } }
            ),
            actions: { Button("OK", role: .cancel) { } },
            message: { Text(unavailableHint ?? "") }
        )
    }

    // MARK: - Mode pills

    @ViewBuilder private var modePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BackgroundMode.allCases) { mode in
                    pill(for: mode)
                }
            }
        }
    }

    @ViewBuilder private func pill(for mode: BackgroundMode) -> some View {
        let isSelected = studio.selectedMode == mode
        let available = mode.isAvailable
        // While the Diffusion download is in flight we don't let the user
        // jump to another mode — `switchMode` would race the URLSession.
        let isBusy: Bool = {
            if case .downloading = studio.phase { return true }
            return false
        }()
        Button {
            if isBusy { return }
            if available {
                studio.selectedMode = mode
            } else {
                // Surface the reason instead of silently doing nothing —
                // a disabled pill with no feedback reads as a bug.
                unavailableHint = mode.unavailableReason
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.systemImage)
                Text(mode.displayName)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : (available ? .primary : .secondary))
            .opacity(available ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
    }

    /// One-line caption explaining the unload/reload tradeoff when the user
    /// picks the Diffusion mode — the VLM has to be released to make room
    /// for HyperSD, and the next VLM call will cold-load.
    @ViewBuilder private var diffusionNotice: some View {
        Label(
            "Diffusion loads first — the VLM is unloaded until the sheet closes.",
            systemImage: "sparkles"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    // MARK: - Main content

    @ViewBuilder private var content: some View {
        switch studio.phase {
        case .idle, .lifting:
            statusRow("Isolating subject…")
        case .suggesting:
            statusRow("Suggesting styles…")
        case .downloading(let update):
            downloadingRow(update)
        case .generating(let mode):
            statusRow("Generating with \(mode.displayName)…")
        case .ready(let candidates):
            candidateGrid(candidates)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text(message).font(.callout).multilineTextAlignment(.center)
                if let reason = studio.selectedMode.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func statusRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// First-time Diffusion download view — shows the current asset (1 of
    /// 4, name) and a percent bar across the whole 947 MB batch.
    @ViewBuilder private func downloadingRow(
        _ update: HyperSDDownloader.Update
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.title)
                .foregroundStyle(.tint)
            Text("Downloading HyperSD weights")
                .font(.headline)
            Text("\(update.assetName) — \(update.assetIndex + 1) of \(update.assetCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: update.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            Text(percentText(update.fraction))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("~947 MB total — runs once per device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func percentText(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return String(format: "%.1f%%", clamped * 100)
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    @ViewBuilder private func candidateGrid(_ candidates: [BackgroundStudio.Candidate]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    candidateThumb(index: index, candidate: candidate)
                }
            }
        }
    }

    @ViewBuilder private func candidateThumb(
        index: Int, candidate: BackgroundStudio.Candidate
    ) -> some View {
        let isPicked = pickedIndex == index
        Button {
            pickedIndex = index
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: candidate.image)
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isPicked ? Color.accentColor : Color.clear,
                                lineWidth: 3
                            )
                    )
                // The VLM-proposed search/generation query. Surfaced so the
                // user can see why a tile looks the way it does (and compare
                // it against the three modes side by side).
                Text(candidate.query)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Apply

    @ViewBuilder private func applyBar(candidates: [BackgroundStudio.Candidate]) -> some View {
        Button {
            guard let index = pickedIndex, candidates.indices.contains(index) else { return }
            onApply(candidates[index].image)
            dismiss()
        } label: {
            Label("Use as hero photo", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(pickedIndex == nil)
    }
}
