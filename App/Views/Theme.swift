import CoreText
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Formwerk's look (see the design canvas): Werk Blue for "act here", Signal Orange for "picked",
/// Space Grotesk for titles, the system font for text, monospaced digits for every number.
enum Theme {
    static let blue = Color.accentColor
    static let signal = Color(red: 1.0, green: 0.541, blue: 0.165)
    /// Green and red for status. Lighter in dark mode so text and icons keep a 4.5 : 1 contrast on glass.
    static let ready = adaptive(light: (0.118, 0.541, 0.298), dark: (0.33, 0.82, 0.52))
    static let problem = adaptive(light: (0.784, 0.196, 0.184), dark: (1.0, 0.45, 0.42))
    static let launchTop = Color(red: 0.18, green: 0.455, blue: 0.941)
    static let launchBottom = Color(red: 0.09, green: 0.247, blue: 0.62)

    /// Space Grotesk (bundled, OFL). Falls back to the system font if it couldn't be loaded.
    static func title(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        fontsRegistered ? .custom("Space Grotesk", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func number(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Corner radii, so panels look like one family. Bars that hold 44 pt capsules use `bar`
    /// (44 + 2 × 6 padding = 56, half of it = 28), which keeps the corners concentric.
    enum Radius {
        static let control: CGFloat = 12
        static let panel: CGFloat = 18
        static let card: CGFloat = 22
        static let bar: CGFloat = 28
    }

    /// Size of panel titles (inspector, coach), Space Grotesk semibold.
    static let panelTitleSize: CGFloat = 20

    /// Smallest comfortable touch target (Apple HIG).
    static let minTouch: CGFloat = 44

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        return Color(UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        return Color(NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
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
    var radius: CGFloat = Theme.Radius.panel
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            // A hairline that stays visible on the dark background too.
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.Radius.panel, padding: CGFloat = 0) -> some View {
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
            .lineLimit(1)
            .padding(.horizontal, 16).frame(minHeight: Theme.minTouch)
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
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .background(prominent ? Theme.blue : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
