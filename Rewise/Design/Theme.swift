import SwiftUI
import UIKit

/// Rewise look: passport navy for the US, burgundy for Hungary, coin gold for highlights.
enum Theme {
    static let navy = Color(light: 0x1E3566, dark: 0xA9C0F2)
    static let burgundy = Color(light: 0x7C1E3D, dark: 0xF0A3BC)
    static let paper = Color(light: 0xF1F3F7, dark: 0x090D16)
    static let sheet = Color(light: 0xFFFFFF, dark: 0x111727)
    static let sheet2 = Color(light: 0xF6F7FA, dark: 0x161D2F)
    static let rule = Color(light: 0xE0E4EC, dark: 0x2A3348)
    static let ink = Color(light: 0x111A2E, dark: 0xE8EBF2)
    static let muted = Color(light: 0x5C6579, dark: 0x98A0B4)
    static let pos = Color(light: 0x11734F, dark: 0x4CC796)
    static let neg = Color(light: 0xB1261C, dark: 0xFF8F86)
    static let warn = Color(light: 0x8A5600, dark: 0xF1BD5A)
    static let button = Color(light: 0x1E3566, dark: 0xE4EAF7)
    static let buttonInk = Color(light: 0xFFFFFF, dark: 0x0E1730)
    static let heroTop = Color(hex: 0x1B2B54)
    static let heroBottom = Color(hex: 0x0F1A33)
    static let seal = Color(hex: 0xD9BD7A)

    /// Bodoni ships with iOS; figures and titles use it the way banknotes use engraved numerals.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom("BodoniSvtyTwoITCTT-Book", size: size, relativeTo: style)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Surfaces and buttons

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rule, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(Theme.buttonInk)
            .background(Theme.button, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

struct HeroButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(primary ? Theme.heroBottom : Color.white)
            .background(primary ? Color.white : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(primary ? 0 : 0.16), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Banknote-style rosette drawn behind the balance.
struct GuillocheView: View {
    var color: Color = Theme.seal.opacity(0.35)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = min(size.width, size.height) / 240
            let bands: [(radius: Double, amplitude: Double, waves: Double, lines: Int)] = [
                (40, 6, 12, 10), (72, 9, 20, 14), (106, 8, 28, 12),
            ]
            for band in bands {
                for line in 0..<band.lines {
                    let phase = Double(line) * 2 * Double.pi / Double(band.lines)
                    var path = Path()
                    for step in 0...360 {
                        let theta = Double(step) / 360 * 2 * Double.pi
                        let r = (band.radius + band.amplitude * sin(band.waves * theta + phase)) * Double(scale)
                        let point = CGPoint(x: Double(center.x) + r * cos(theta), y: Double(center.y) + r * sin(theta))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 0.6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
