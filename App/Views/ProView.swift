import StoreKit
import SwiftUI

/// The calm, honest paywall for the one-time Formwerk Pro unlock.
struct ProView: View {
    /// For the "thank you" toast after a purchase.
    var model: EditorModel?
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 16) {
                        feature("square.and.arrow.up.on.square", "Export 3MF, STEP, OBJ and USDZ",
                                "Colours and bodies for your slicer, exact geometry for other CAD apps.")
                        feature("square.and.arrow.down", "Import STEP files",
                                "Open parts from other CAD apps and keep working on them.")
                        feature("arkit", "View in AR",
                                "On iPad and iPhone: place your part on the desk at real size.")
                        feature("rotate.3d", "Auto-orient",
                                "Finds the way round with the least overhang.")
                        feature("square.on.square.dashed", "Pattern, Hollow and Split",
                                "Repeat bodies, hollow them out to save filament, cut big parts to fit your printer.")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "heart").font(.title3).frame(width: 30).foregroundStyle(Theme.signal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Everything else stays free.").font(.headline)
                            Text("Sketching, all modelling tools, templates, the print check and STL export. No limits, no ads.")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    actions
                }
                .padding(28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(store.isPro ? "Done" : "Not now") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 680)
        #endif
        .task {
            store.clearMessage()
            await store.load()
        }
        .onChange(of: store.state) { _, s in
            if s == .purchased { finish() }
        }
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.blue)
                Image(systemName: "cube.transparent")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            Text("Formwerk Pro").font(Theme.title(34))
            Text("Pay once. Yours on iPad, iPhone and Mac.")
                .font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if store.isPro {
                Label("You have Formwerk Pro. Thank you!", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ready)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
            } else {
                Button {
                    if store.product == nil {
                        Task { await store.load() }
                    } else {
                        Task { await store.purchase(using: purchase) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        if let p = store.product {
                            Text("Buy for \(p.displayPrice)")
                        } else if store.loadFailed {
                            Text("Try Again")
                        } else {
                            Text("Loading price…")
                        }
                    }
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                .disabled(busy || (store.product == nil && !store.loadFailed))

                Button("Restore Purchases") { Task { await store.restore() } }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(busy)
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(messageIsError ? Theme.problem : Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            Text("One-time purchase, no subscription.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var busy: Bool {
        store.state == .purchasing || store.state == .restoring || store.isLoading
    }

    private var message: String? {
        if store.isPro { return nil }
        if store.product == nil && store.loadFailed {
            return String(localized: "The App Store can't be reached right now. Please try again later.")
        }
        switch store.state {
        case .pending:
            return String(localized: "Waiting for approval. Pro unlocks by itself once it's approved.")
        case .failed(let reason):
            return String(localized: "The purchase didn't go through: \(reason)")
        case .nothingToRestore:
            return String(localized: "No earlier purchase was found for this Apple Account.")
        default:
            return nil
        }
    }

    private var messageIsError: Bool {
        if case .failed = store.state { return true }
        return store.product == nil && store.loadFailed
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Theme.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        model?.show(String(localized: "Formwerk Pro is unlocked. Thank you!"))
        dismiss()
    }
}
