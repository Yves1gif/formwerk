import CoreText
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Formwerk's look (see the design canvas): Werk Blue for "act here", Signal Orange for "picked",
/// Space Grotesk for titles, the system font for text, monospaced digits for every number.
///
/// The design system is split in three places:
/// - here: colours, type, spacing and radius tokens, the button styles;
/// - `Design/Glass.swift`: Liquid Glass on iOS/macOS 26 with the material look as the fallback;
/// - `Design/Motion.swift`: `Theme.Motion` (springs), `Theme.Haptics`, appear/hover/shake helpers.
enum Theme {
    static let blue = Color.accentColor
    static let signal = Color(red: 1.0, green: 0.541, blue: 0.165)
    /// Green and red for status. Lighter in dark mode so text and icons keep a 4.5 : 1 contrast on glass.
    static let ready = adaptive(light: (0.118, 0.541, 0.298), dark: (0.33, 0.82, 0.52))
    static let problem = adaptive(light: (0.784, 0.196, 0.184), dark: (1.0, 0.45, 0.42))
    /// Amber for "worth a look" (overhangs, warnings). Darker in light mode for contrast on white.
    static let caution = adaptive(light: (0.80, 0.42, 0.0), dark: (1.0, 0.66, 0.25))
    static let launchTop = Color(red: 0.18, green: 0.455, blue: 0.941)
    static let launchBottom = Color(red: 0.09, green: 0.247, blue: 0.62)

    /// Panel background when Reduce Transparency is on: opaque, still lifted from the 3D view.
    #if os(iOS)
    static let opaquePanel = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    static let opaquePanel = Color(nsColor: .controlBackgroundColor)
    #endif
    /// The thin edge around panels and chips (visible on light and dark backgrounds).
    static let hairline = Color.primary.opacity(0.08)
    /// Quiet fill for secondary controls inside panels (chips, step buttons, tiles).
    static let quietFill = Color.primary.opacity(0.07)

    /// Space Grotesk (bundled, OFL). Falls back to the system font if it couldn't be loaded.
    static func title(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        fontsRegistered ? .custom("Space Grotesk", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func number(_ size: CGFloat = 15, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Spacing on the 8 pt grid (4 is the half step for tight groups).
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 40
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
    /// Big, calm titles at the top of sheets (Print, Welcome).
    static let sheetTitleSize: CGFloat = 28

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

/// The floating panels over the 3D view: Liquid Glass on iOS/macOS 26, the material look before,
/// an opaque panel with Reduce Transparency (see `FormwerkGlass`).
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.Radius.panel
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .formwerkGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func glassPanel(radius: CGFloat = Theme.Radius.panel, padding: CGFloat = 0) -> some View {
        modifier(GlassPanel(radius: radius, padding: padding))
    }
}

// MARK: - Button styles

/// Capsule buttons for the context bar and tool chips. They sit on a glass bar, so they use
/// solid fills (no glass on glass): Werk Blue when prominent, a quiet fill otherwise.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.callout.weight(prominent ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m).frame(minHeight: Theme.minTouch)
            .background(background, in: Capsule())
            .foregroundStyle(prominent ? Color.white : destructive ? Theme.problem : Color.primary)
            .contentShape(Capsule())
            .hoverHighlight(Capsule())
            .pressScale(configuration.isPressed, to: 0.95)
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var background: Color {
        if prominent { return Theme.blue }
        if destructive { return Theme.problem.opacity(0.12) }
        return Theme.quietFill
    }
}

/// Big rounded buttons for panel actions (Done / Cancel).
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct PanelButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        configuration.label
            .font(.body.weight(prominent ? .bold : .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            .background(prominent ? Theme.blue : Color.primary.opacity(0.08), in: shape)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(shape)
            .hoverHighlight(shape)
            .pressScale(configuration.isPressed, to: 0.97)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// For the tool rail (`RailButton` in Toolbars.swift): a 60 pt tile, Werk Blue when active,
/// a hover highlight on iPad pointer and Mac, a small press. Use with `.buttonStyle(RailButtonStyle(active:))`.
struct RailButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        RailButtonBody(configuration: configuration, active: active)
    }
}

private struct RailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        configuration.label
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Theme.blue : Color.clear, in: shape)
            .contentShape(shape)
            .hoverHighlight(shape)
            .pressScale(configuration.isPressed, to: 0.93)
            .animation(Theme.Motion.snappy, value: active)
    }
}

/// A plain button that shrinks a little while pressed (chips, cards, swatches).
struct PressScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressScale(configuration.isPressed, to: scale)
    }
}
