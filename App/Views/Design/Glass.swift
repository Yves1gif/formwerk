import SwiftUI

// Liquid Glass in one place. Every iOS/macOS 26 API is behind `#available`, so the app still
// builds for iOS 18 / macOS 14 and looks like before there (regular material + hairline + soft shadow).
// With Reduce Transparency the panels become opaque on every OS version.

/// Glass behind content, in any shape that can draw a border.
struct FormwerkGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    ZStack {
                        shape.fill(Theme.opaquePanel)
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        if let tint { shape.fill(tint.opacity(0.18)) }
                    }
                }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14)))
        } else {
            if #available(iOS 26, macOS 26, *) {
                content.glassEffect(Self.glass(tint: tint, interactive: interactive), in: shape)
            } else {
                content
                    .background {
                        ZStack {
                            shape.fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                            if let tint { shape.fill(tint.opacity(0.16)) }
                        }
                    }
                    .overlay(shape.strokeBorder(Theme.hairline))
            }
        }
    }

    @available(iOS 26, macOS 26, *)
    private static func glass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups neighbouring glass so it blends and morphs (`GlassEffectContainer` on 26, a plain
/// pass-through before).
struct FormwerkGlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Glass in a shape. `interactive` makes it react to touch (tappable chips); `tint` colours it
    /// (selected state). Legible over the 3D view; opaque with Reduce Transparency.
    func formwerkGlass<S: InsettableShape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(FormwerkGlass(shape: shape, interactive: interactive, tint: tint))
    }

    /// Glass in a continuous rounded rectangle (the panel family).
    func formwerkGlass(radius: CGFloat = Theme.Radius.panel, interactive: Bool = false, tint: Color? = nil) -> some View {
        formwerkGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), interactive: interactive, tint: tint)
    }

    /// Lets two glass shapes in the same `FormwerkGlassGroup` morph into each other (26+ only).
    @ViewBuilder
    func formwerkGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26, macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// System glass buttons on 26 (`.glass` / `.glassProminent`), bordered buttons before.
    @ViewBuilder
    func formwerkGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// A bar pinned to the bottom of a scrolling sheet. On 26 it is a `safeAreaBar` (the content
    /// scrolls under it with the system edge effect); before, a safe-area inset on the bar material.
    @ViewBuilder
    func formwerkBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom) { bar() }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
    }
}
