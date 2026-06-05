import SwiftUI
import UIKit
import VLMKit

/// Drives the background-generation flow: subject lift → VLM style suggestions
/// → mode-specific background generation → compositing → candidate list. Acts
/// as a small `ObservableObject` so the SwiftUI sheet can react to its
/// progress, error, and final candidates.
@MainActor
final class BackgroundStudio: ObservableObject {

    /// One generated candidate carries the composited image and the original
    /// VLM-proposed query string so the UI can label each tile with what the
    /// model asked for — useful for understanding why a candidate looks the
    /// way it does.
    struct Candidate: Equatable {
        let query: String
        let image: UIImage
    }

    enum Phase: Equatable {
        case idle
        case lifting
        case suggesting
        /// First-time use of the Diffusion mode — downloading the ~947 MB of
        /// HyperSD weights from the CoreML-Models release.
        case downloading(HyperSDDownloader.Update)
        case generating(mode: BackgroundMode)
        case ready(candidates: [Candidate])
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var selectedMode: BackgroundMode = .solidGradient

    /// The lifted subject from the first run — kept so changing the mode
    /// doesn't have to re-lift (Vision is fast, but the user pays attention
    /// to every spinner).
    private var subject: LiftedSubject?
    private var suggestions: [BackgroundStyleSuggestion] = []
    private let compositor = BackgroundCompositor()

    /// Cached across mode switches so flipping back to Diffusion in the same
    /// sheet doesn't cold-load HyperSD's ~2 GB weights again. `reset()` (sheet
    /// dismiss) drops it.
    private var hyperSDBackground: HyperSDBackground?

    /// Kick the whole pipeline: lift the subject from `sourceImage`, ask the
    /// VLM for style suggestions, then run the currently `selectedMode`'s
    /// generator and composite each candidate. Called when the sheet appears
    /// or when the user switches mode.
    func run(on sourceImage: UIImage, runner: VLMRunner, vlmImage: VLMImage) async {
        phase = .lifting
        if subject == nil {
            guard let sourceCG = sourceImage.cgImage else {
                phase = .failed("Could not read the source photo.")
                return
            }
            subject = await SubjectLifter.lift(from: sourceCG)
        }
        guard let subject else {
            phase = .failed("Could not isolate the subject from the photo.")
            return
        }
        if suggestions.isEmpty {
            phase = .suggesting
            do {
                suggestions = try await Listing.suggestBackgroundStyles(
                    on: [vlmImage], runner: runner
                )
            } catch {
                phase = .failed("Background style suggestion failed: \(error.localizedDescription)")
                return
            }
            if suggestions.isEmpty {
                // VLM refused or returned nothing — fall back to a single
                // neutral style so the user still sees something.
                suggestions = [BackgroundStyleSuggestion(query: "clean off white studio", color: "off white")]
            }
        }
        await generate(using: subject)
    }

    /// Re-render candidates against the existing subject when the user
    /// switches mode. Re-uses the cached suggestions — no second VLM call.
    func switchMode(to mode: BackgroundMode) async {
        // A mid-download mode switch would race the in-flight URLSession
        // with the new generator's run; just stay put until the download
        // settles.
        if case .downloading = phase { return }
        guard mode.isAvailable, selectedMode != mode else { return }
        selectedMode = mode
        guard let subject else { return }  // initial run hasn't completed
        await generate(using: subject)
    }

    // MARK: - Generation

    private func generate(using subject: LiftedSubject) async {
        let mode = selectedMode

        // Diffusion's first use downloads ~947 MB from the CoreML-Models
        // release. Run that as its own phase so the user sees fine-grained
        // progress instead of a generic spinner — Solid / Pexels skip this
        // step entirely.
        if mode == .diffusion, !HyperSDBackground.areModelsPresent {
            if hyperSDBackground == nil { hyperSDBackground = HyperSDBackground() }
            do {
                try await hyperSDBackground!.downloadIfNeeded { @Sendable update in
                    Task { @MainActor [weak self] in
                        self?.phase = .downloading(update)
                    }
                }
            } catch {
                phase = .failed("Could not download HyperSD models: \(error.localizedDescription)")
                return
            }
        }

        phase = .generating(mode: mode)
        let generator: BackgroundGenerator
        switch mode {
        case .solidGradient: generator = SolidGradientBackground()
        case .pexels: generator = PexelsBackground()
        case .diffusion:
            if hyperSDBackground == nil { hyperSDBackground = HyperSDBackground() }
            generator = hyperSDBackground!
        }
        var candidates: [Candidate] = []
        for suggestion in suggestions {
            // Each mode wants a different shape of style hint:
            //   - Solid wants a palette token (falls back to the query if the
            //     VLM didn't tag a color).
            //   - Pexels wants 2–4 short search keywords (falls back to the
            //     long query, which still returns *some* results).
            //   - Diffusion wants the rich, descriptive scene.
            let style: String = {
                switch mode {
                case .solidGradient: return suggestion.color ?? suggestion.query
                case .pexels: return suggestion.keywords ?? suggestion.query
                case .diffusion: return suggestion.query
                }
            }()
            do {
                let backgrounds = try await generator.generate(
                    style: style, count: 1, canvasSize: BackgroundCompositor.defaultCanvas
                )
                for background in backgrounds {
                    if let composed = compositor.compose(subject: subject, background: background) {
                        candidates.append(Candidate(query: suggestion.query, image: composed))
                    }
                }
            } catch {
                // Single-suggestion failure is non-fatal — keep going so the
                // user still sees the rest. If everything fails, the phase
                // below flips to .failed.
                continue
            }
        }
        if candidates.isEmpty {
            phase = .failed("No backgrounds could be generated.")
        } else {
            phase = .ready(candidates: candidates)
        }
    }

    /// Drop everything so opening the sheet again on a different photo starts
    /// fresh. Called by the view's `onDisappear`. Also releases the HyperSD
    /// pipeline so the VLM can reclaim the RAM it was holding for Diffusion.
    func reset() {
        subject = nil
        suggestions = []
        phase = .idle
        hyperSDBackground?.unload()
        hyperSDBackground = nil
    }
}
