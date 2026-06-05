import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Programmatic backgrounds — solid colors and soft linear/radial gradients
/// rendered via Core Image. Zero external assets, zero network, zero copyright
/// risk. The VLM's "color" hint ("warm beige", "cool gray", "deep navy") is
/// snapped to a curated palette so output stays photogenic.
struct SolidGradientBackground: BackgroundGenerator {

    /// Curated palette of marketplace-friendly tones (clean studio-y rather
    /// than fluorescent). Keys are the color tokens we ask the VLM to use.
    private static let palette: [String: UIColor] = [
        "white": UIColor(white: 0.98, alpha: 1),
        "off white": UIColor(white: 0.96, alpha: 1),
        "warm beige": UIColor(red: 0.94, green: 0.89, blue: 0.81, alpha: 1),
        "cream": UIColor(red: 0.97, green: 0.94, blue: 0.86, alpha: 1),
        "cool gray": UIColor(white: 0.86, alpha: 1),
        "warm gray": UIColor(red: 0.86, green: 0.83, blue: 0.80, alpha: 1),
        "soft pink": UIColor(red: 0.97, green: 0.88, blue: 0.86, alpha: 1),
        "sage green": UIColor(red: 0.78, green: 0.85, blue: 0.79, alpha: 1),
        "deep navy": UIColor(red: 0.10, green: 0.18, blue: 0.32, alpha: 1),
        "charcoal": UIColor(white: 0.18, alpha: 1),
        "wood brown": UIColor(red: 0.55, green: 0.42, blue: 0.30, alpha: 1),
    ]

    /// Three styles produced per call: solid + linear gradient + radial
    /// gradient using the same color. Easy way to give the user variety
    /// without recomputing palette lookups.
    func generate(
        style: String,
        count: Int,
        canvasSize: CGSize
    ) async throws -> [UIImage] {
        let base = Self.color(for: style)
        let companion = Self.companion(for: base)
        let styles: [(UIColor, UIColor, GradientShape)] = [
            (base, base, .solid),
            (base, companion, .linear),
            (companion, base, .radial),
        ]
        let chosen = Array(styles.prefix(count))
        return chosen.compactMap { primary, secondary, shape in
            render(size: canvasSize, primary: primary, secondary: secondary, shape: shape)
        }
    }

    // MARK: - Color resolution

    /// Resolve the VLM's free-text style to a palette color. Strategy: exact
    /// key match → contains match → fallback "off white". Case- and
    /// whitespace-insensitive.
    static func color(for style: String) -> UIColor {
        let lower = style.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = palette[lower] { return exact }
        if let partial = palette.first(where: { lower.contains($0.key) }) {
            return partial.value
        }
        return palette["off white"]!
    }

    /// Pick a "companion" tone for the gradient — slightly lighter or darker
    /// than the base so gradients feel intentional rather than muddy.
    private static func companion(for color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let shift: CGFloat = brightness > 0.6 ? -0.10 : 0.18
        let adjusted = max(0, min(1, brightness + shift))
        return UIColor(hue: hue, saturation: saturation, brightness: adjusted, alpha: alpha)
    }

    // MARK: - Rendering

    private enum GradientShape { case solid, linear, radial }

    private func render(
        size: CGSize,
        primary: UIColor,
        secondary: UIColor,
        shape: GradientShape
    ) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgContext = ctx.cgContext
            switch shape {
            case .solid:
                cgContext.setFillColor(primary.cgColor)
                cgContext.fill(CGRect(origin: .zero, size: size))
            case .linear:
                let colors = [primary.cgColor, secondary.cgColor] as CFArray
                let space = CGColorSpaceCreateDeviceRGB()
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    cgContext.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: 0),
                        end: CGPoint(x: 0, y: size.height),
                        options: []
                    )
                }
            case .radial:
                let colors = [primary.cgColor, secondary.cgColor] as CFArray
                let space = CGColorSpaceCreateDeviceRGB()
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
                    let radius = max(size.width, size.height) * 0.6
                    cgContext.drawRadialGradient(
                        gradient,
                        startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: radius,
                        options: []
                    )
                }
            }
            // Subtle film grain — keeps the gradient from looking flat /
            // banded on OLED screens.
            cgContext.setAlpha(0.02)
            cgContext.setFillColor(UIColor.black.cgColor)
            let step: CGFloat = 4
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = .random(in: 0..<step)
                while x < size.width {
                    cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    x += step
                }
                y += step
            }
        }
        return image
    }
}
