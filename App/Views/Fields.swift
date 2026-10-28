import simd
import SwiftUI

/// A length input that understands maths and units: `20+5`, `50/2`, `1in`, `12,5`.
/// Shows −/+ buttons for quick steps on touch screens.
struct LengthField: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    var unit: LengthUnit = .mm
    var step: Double = 1
    var range: ClosedRange<Double> = -100_000...100_000
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        FieldRow(title: title) {
            StepButton(icon: "minus", label: "Decrease") { set(value - step * unit.millimetres) }
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .font(Theme.number())
                .frame(width: 88)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(Text(title))
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            StepButton(icon: "plus", label: "Increase") { set(value + step * unit.millimetres) }
        }
        .onAppear { text = display(value) }
        .onChange(of: value) { _, v in if !focused { text = display(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func display(_ mm: Double) -> String { "\(Format.number(mm / unit.millimetres, digits: 3)) \(unit.symbol)" }

    private func commit() {
        if let v = Expression.parseLength(text, defaultUnit: unit) { set(v) } else { text = display(value) }
    }

    private func set(_ v: Double) {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        value = clamped
        text = display(clamped)
    }
}

/// An angle input in degrees (stored as radians).
struct AngleField: View {
    let title: LocalizedStringKey
    @Binding var radians: Double
    var step: Double = 15
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        FieldRow(title: title) {
            StepButton(icon: "minus", label: "Decrease") { set(radians * 180 / .pi - step) }
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .font(Theme.number())
                .frame(width: 88)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel(Text(title))
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            StepButton(icon: "plus", label: "Increase") { set(radians * 180 / .pi + step) }
        }
        .onAppear { text = Format.angle(radians) }
        .onChange(of: radians) { _, v in if !focused { text = Format.angle(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let r = Expression.parseAngle(text) { radians = r; text = Format.angle(r) } else { text = Format.angle(radians) }
    }

    private func set(_ deg: Double) {
        radians = deg * .pi / 180
        text = Format.angle(radians)
    }
}

/// Label on the left, controls on the right. When a translation is too long for one line
/// (e.g. German "Kopfdurchmesser"), the label moves above the controls instead of shrinking or clipping.
struct FieldRow<Controls: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        FieldRowLayout {
            label
            HStack(spacing: 4) { controls() }
        }
    }

    private var label: some View {
        Text(title).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
    }
}

/// Two subviews (label, controls): side by side when they fit, otherwise the label wraps above the
/// controls. A Layout (not ViewThatFits) so the text field exists only once and keeps its focus.
/// SwiftUI mirrors custom layouts for right-to-left languages.
struct FieldRowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let label = subviews[0].sizeThatFits(.unspecified)
        let controls = subviews[1].sizeThatFits(.unspecified)
        let ideal = label.width + spacing + controls.width
        var width = proposal.width ?? ideal
        if !width.isFinite { width = ideal }
        if label.width + spacing + controls.width <= width {
            return CGSize(width: width, height: max(label.height, controls.height))
        }
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: wrapped.height + 4 + controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let label = subviews[0].sizeThatFits(.unspecified)
        let controls = subviews[1].sizeThatFits(.unspecified)
        if label.width + spacing + controls.width <= bounds.width {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(label))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(controls))
        } else {
            let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: wrapped.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing, proposal: ProposedViewSize(controls))
        }
    }
}

/// The round −/+ buttons next to number fields: a 28 pt circle inside a 36 × 44 pt tap area.
struct StepButton: View {
    let icon: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.07), in: Circle())
                .frame(width: 36, height: Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        #if os(iOS)
        .buttonRepeatBehavior(.enabled)
        #endif
    }
}

/// Section header inside panels.
struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            content()
        }
    }
}

/// A small picker row with a label.
struct PickerRow<T: Hashable, Content: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: T
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary).accessibilityHidden(true)
            Spacer(minLength: 8)
            Picker(title, selection: $selection, content: content).labelsHidden().pickerStyle(.menu).fixedSize()
        }
        .frame(minHeight: Theme.minTouch)
    }
}
