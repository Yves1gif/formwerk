import SwiftUI

/// Shown once on narrow iPhone screens (a normal iPhone, or an iPhone Duo while folded).
/// Formwerk is made for the Duo's inner screen, but it runs on every iPhone in the compact layout.
/// On a Duo, unfolding switches to the full editor by itself.
struct UnfoldView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "iphone.gen3")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Theme.blue)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("Made for iPhone Duo")
                .font(Theme.title(28, weight: .bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Formwerk was designed for the big screen of iPhone Duo, iPad and Mac. It works on this iPhone too, but tools can feel a bit cramped.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("On an iPhone Duo, just unfold it for the full editor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Continue", action: onContinue)
                .buttonStyle(PillButtonStyle(prominent: true))
                .padding(.bottom, 16)
        }
        // Comfortable line length on the unfolded or landscape screen.
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
