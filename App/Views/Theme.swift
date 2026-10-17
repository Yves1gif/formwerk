import CoreText
import SwiftUI

/// Formwerk's look (see the design canvas): Werk Blue for "act here", Signal Orange for "picked",
/// Space Grotesk for titles, the system font for text, monospaced digits for every number.
enum Theme {
    static let blue = Color.accentColor
    static let signal = Color(red: 1.0, green: 0.541, blue: 0.165)
    static let ready = Color(red: 0.118, green: 0.541, blue: 0.298)
    static let problem = Color(red: 0.784, green: 0.196, blue: 0.184)
    static let launchTop = Color(red: 0.18, green: 0.455, blue: 0.941)
    static let launchBottom = Color(red: 0.09, green: 0.247, blue: 0.62)

    /// Space Grotesk (bundled, OFL). Falls back to the system font if it couldn't be loaded.
    static func title(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        fontsRegistered ? .custom("Space Grotesk", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func number(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    nonisolated(unsafe) private static var fontsRegistered = false

    static func registerFonts() {
        guard !fontsRegistered, let url = Bundle.main.url(forResource: "SpaceGrotesk", withExtension: "ttf") else { return }
        var error: Unmanaged<CFError>?
        fontsRegistered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) || error != nil
    }
}

/// The floating glass panels over the 3D view.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 18
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

extension View {
    func glassPanel(radius: CGFloat = 18, padding: CGFloat = 0) -> some View {
        modifier(GlassPanel(radius: radius, padding: padding))
    }
}

/// Capsule buttons for the context bar and tool chips.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .medium))
            .padding(.horizontal, 15).frame(minHeight: 40)
            .background(background, in: Capsule())
            .foregroundStyle(prominent ? Color.white : destructive ? Theme.problem : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }

    private var background: Color {
        if prominent { return Theme.blue }
        if destructive { return Theme.problem.opacity(0.12) }
        return Color.primary.opacity(0.07)
    }
}

/// Big rounded buttons for panel actions (Done / Cancel).
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(prominent ? .bold : .semibold))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(prominent ? Theme.blue : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
