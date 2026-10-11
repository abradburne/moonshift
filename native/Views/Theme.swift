import SwiftUI

/// Moonshift at night: a cool moon for the original song, a warm one for the cover.
enum Theme {
    /// Warm moonlight. The new sound, and everything you can act on.
    static let accent = Color(red: 1.0, green: 0.76, blue: 0.42)
    /// Cool moonlight. The original song.
    static let cool = Color(red: 0.60, green: 0.72, blue: 1.0)
    static let background = Color(red: 0.047, green: 0.055, blue: 0.082)
    static let surface = Color.white.opacity(0.055)
    static let surfaceRaised = Color.white.opacity(0.09)
    static let stroke = Color.white.opacity(0.09)
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.35)
    /// Text set on the accent colour.
    static let onAccent = Color(red: 0.13, green: 0.09, blue: 0.03)

    static let nsAccent = NSColor(red: 1.0, green: 0.76, blue: 0.42, alpha: 1)
    static let contentWidth: CGFloat = 720
    static let radius: CGFloat = 16
}

extension View {
    /// A quiet raised panel.
    func card(padding: CGFloat = 20, radius: CGFloat = Theme.radius) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.stroke))
    }

    /// Liquid Glass where the system has it, a material elsewhere.
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape).overlay(shape.stroke(Theme.stroke))
        }
    }
}

/// The one thing to do next.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(enabled ? Theme.onAccent : Color.white.opacity(0.35))
            .padding(.horizontal, large ? 26 : 18)
            .padding(.vertical, large ? 12 : 8)
            .background(enabled ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A supporting action that sits beside a primary one.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(enabled ? .primary : .tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.surfaceRaised : Theme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .contentShape(Capsule())
    }
}

/// A selectable tile: presets, singers, options.
struct TileButtonStyle: ButtonStyle {
    var selected: Bool
    var tint = Theme.accent
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .background(selected ? AnyShapeStyle(tint.opacity(0.14)) : AnyShapeStyle(hovering ? Theme.surfaceRaised : Theme.surface), in: shape)
            .overlay(shape.strokeBorder(selected ? tint.opacity(0.75) : Theme.stroke, lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.15), value: selected)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryLarge: PrimaryButtonStyle { PrimaryButtonStyle(large: true) }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}
