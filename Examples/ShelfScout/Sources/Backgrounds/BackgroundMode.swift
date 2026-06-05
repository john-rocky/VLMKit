import UIKit

/// Which background-generation pipeline the BackgroundStudio uses. The enum is
/// ordered by feasibility (Solid always available; Pexels needs a key; Diffusion
/// needs a sideloaded model + capable device). UI only shows modes whose
/// `isAvailable` is true at runtime.
enum BackgroundMode: String, CaseIterable, Identifiable {
    case solidGradient
    case pexels
    case diffusion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solidGradient: "Solid / Gradient"
        case .pexels: "Pexels"
        case .diffusion: "AI Diffusion"
        }
    }

    var systemImage: String {
        switch self {
        case .solidGradient: "square.fill.on.circle.fill"
        case .pexels: "photo.stack"
        case .diffusion: "sparkles"
        }
    }

    /// Static availability check at app-launch resolution. Diffusion's
    /// runtime check covers sideloaded weights + device RAM + jetsam headroom
    /// — see `HyperSDBackground.isAvailable`.
    var isAvailable: Bool {
        switch self {
        case .solidGradient: true
        case .pexels: PexelsAPIKey.isPresent
        case .diffusion: HyperSDBackground.isAvailable
        }
    }

    /// Short user-facing reason the mode is disabled. `nil` when available.
    var unavailableReason: String? {
        switch self {
        case .solidGradient: nil
        case .pexels:
            PexelsAPIKey.isPresent ? nil : "Add a Pexels API key in PexelsAPIKey.swift"
        case .diffusion:
            HyperSDBackground.isAvailable
                ? nil
                : "Needs iPhone 15+ with 6 GB RAM (first run downloads ~947 MB)"
        }
    }
}

/// A single background-generation pipeline. Implementations live next to this
/// file (one per mode). All return ready-to-composite full-frame backgrounds —
/// the compositor never has to know which mode produced them.
protocol BackgroundGenerator {
    /// Produce `count` background images at roughly the requested canvas size.
    /// `style` is the VLM's free-text suggestion ("clean white studio",
    /// "warm wood tabletop", "soft beige gradient") — each generator interprets
    /// it however it can (Solid maps to color tokens, Pexels feeds it as a
    /// search query, Diffusion uses it as a prompt). Throwing means the whole
    /// candidate set failed; the orchestrator will surface that to the UI.
    func generate(
        style: String,
        count: Int,
        canvasSize: CGSize
    ) async throws -> [UIImage]
}

// `BackgroundStyleSuggestion` lives in VLMKit's Listing recipe — see
// `Listing.suggestBackgroundStyles`. The app uses it directly here so style
// hints don't get re-typed at the module boundary.
