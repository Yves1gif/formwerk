import SwiftUI

/// Shown on narrow iPhone screens (a normal iPhone, or an iPhone Duo while folded).
/// Formwerk is made for the Duo's inner screen; it moves on by itself when you unfold.
struct UnfoldView: View {
    let openAnyway: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Theme.blue)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("Unfold your iPhone")
                .font(Theme.title(28, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Formwerk is made for big screens. Open your iPhone Duo to design with the full editor.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("On other iPhones, use Formwerk on your iPad or Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open anyway", action: openAnyway)
                .buttonStyle(PillButtonStyle())
                .padding(.bottom, 16)
        }
        // Comfortable line length on the unfolded or landscape screen.
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
