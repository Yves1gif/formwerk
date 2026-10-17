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
        HStack(spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            stepButton("minus") { set(value - step * unit.millimetres) }
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .font(Theme.number())
                .frame(width: 88)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            stepButton("plus") { set(value + step * unit.millimetres) }
        }
        .onAppear { text = display(value) }
        .onChange(of: value) { _, v in if !focused { text = display(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func stepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.bold)).frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
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
        HStack(spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { set(radians * 180 / .pi - step) } label: {
                Image(systemName: "minus").font(.caption.weight(.bold)).frame(width: 26, height: 26).background(Color.primary.opacity(0.07), in: Circle())
            }.buttonStyle(.plain)
            TextField("", text: $text)
                .multilineTextAlignment(.trailing)
                .font(Theme.number())
                .frame(width: 74)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
            Button { set(radians * 180 / .pi + step) } label: {
                Image(systemName: "plus").font(.caption.weight(.bold)).frame(width: 26, height: 26).background(Color.primary.opacity(0.07), in: Circle())
            }.buttonStyle(.plain)
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
        HStack {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Picker(title, selection: $selection, content: content).labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }
}
