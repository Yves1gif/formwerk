import StoreKit
import SwiftUI

/// What Formwerk Pro adds. Everything else stays free.
enum ProFeature: String, CaseIterable, Identifiable {
    case exportFormats, stepImport, arView, autoOrient, pattern, hollow, split
    var id: String { rawValue }
}

extension ToolKind {
    /// The Pro feature behind this tool, if any. Only *starting* one of these is gated:
    /// designs that already contain such a step still rebuild and stay editable.
    var proFeature: ProFeature? {
        switch self {
        case .pattern: .pattern
        case .shell: .hollow
        case .split: .split
        default: nil
        }
    }
}

extension ExportFormat {
    /// STL stays free; the richer formats come with Pro.
    var isPro: Bool { self != .stl }
}

/// The one-time "Formwerk Pro" unlock (non-consumable, StoreKit 2, verified on the device).
/// No server, no subscription. Universal Purchase and Family Sharing make it work on every device.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.yvesf.formwerk.pro"

    enum State: Equatable {
        case idle
        case purchasing
        /// Ask to Buy: waiting for a parent's approval. Unlocks by itself via `StoreKit.Transaction.updates`.
        case pending
        case cancelled
        case failed(String)
        case restoring
        case nothingToRestore
        case purchased
    }

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    @Published private(set) var state: State = .idle

    /// Last known entitlement, so the app doesn't flash "PRO" badges at launch before StoreKit answers.
    private static let cacheKey = "formwerkProUnlocked"
    private var owned: Bool
    private var updatesTask: Task<Void, Never>?

    private init() {
        owned = UserDefaults.standard.bool(forKey: Self.cacheKey)
        isPro = owned || Self.forcedPro
        // Purchases made elsewhere (other device, Ask to Buy approval, refunds) arrive here.
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                await self?.handle(result)
            }
        }
        Task { [weak self] in await self?.refreshEntitlements() }
    }

    /// App Store screenshots show everything; in Debug builds `-formwerkPro YES` unlocks too.
    private static var forcedPro: Bool {
        if ScreenshotMode.current != nil { return true }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "formwerkPro") { return true }
        #endif
        return false
    }

    private func setOwned(_ value: Bool) {
        owned = value
        UserDefaults.standard.set(value, forKey: Self.cacheKey)
        let pro = value || Self.forcedPro
        if pro != isPro { isPro = pro }
    }

    // MARK: - Gate

    /// True when Pro is unlocked; otherwise calls `showPaywall` and returns false.
    @discardableResult
    func requirePro(_ feature: ProFeature, else showPaywall: () -> Void) -> Bool {
        if isPro { return true }
        showPaywall()
        return false
    }

    // MARK: - StoreKit

    /// Forgets an old message (cancelled, failed …) when the paywall opens again.
    func clearMessage() {
        switch state {
        case .purchasing, .restoring, .pending: break
        default: state = .idle
        }
    }

    /// Loads the product (for its localized price).
    func load() async {
        guard product == nil, !isLoading else { return }
        isLoading = true
        loadFailed = false
        do {
            product = try await Product.products(for: [Self.productID]).first
            loadFailed = product == nil
        } catch {
            loadFailed = true
        }
        isLoading = false
    }

    /// Buys Pro. Pass SwiftUI's `@Environment(\.purchase)` so the sheet attaches to the right window.
    func purchase(using action: PurchaseAction? = nil) async {
        if product == nil { await load() }
        guard let product else { return }
        state = .purchasing
        do {
            let result: Product.PurchaseResult
            if let action {
                result = try await action(product)
            } else {
                result = try await product.purchase()
            }
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    setOwned(transaction.revocationDate == nil)
                    state = isPro ? .purchased : .idle
                case .unverified(_, let error):
                    state = .failed(error.localizedDescription)
                }
            case .pending:
                state = .pending
            case .userCancelled:
                state = .cancelled
            @unknown default:
                state = .idle
            }
        } catch StoreKitError.userCancelled {
            state = .cancelled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// "Restore Purchases": syncs with the App Store, then re-reads the entitlements.
    func restore() async {
        state = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            state = owned ? .purchased : .nothingToRestore
        } catch StoreKitError.userCancelled {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reads what this Apple Account owns (works offline, StoreKit keeps it on the device).
    func refreshEntitlements() async {
        var found = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil {
                found = true
            }
        }
        if !found { found = await boughtBeforePro() }
        setOwned(found)
    }

    /// Version 1.0 had every export free. Whoever got the app before Pro existed keeps it all:
    /// their original download is an older build (build numbers are yyyyMMddHHmm timestamps).
    private func boughtBeforePro() async -> Bool {
        guard case .verified(let app)? = try? await AppTransaction.shared, app.environment == .production,
              let build = Int(app.originalAppVersion) else { return false }
        return build < 202610280000
    }

    private func handle(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.productID == Self.productID {
            await refreshEntitlements()
            if owned, state == .pending { state = .purchased }
        }
        await transaction.finish()
    }
}

/// The small "PRO" capsule next to Pro features.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.6)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.blue.opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.blue)
            .fixedSize()
            .accessibilityLabel(Text("Formwerk Pro"))
    }
}
