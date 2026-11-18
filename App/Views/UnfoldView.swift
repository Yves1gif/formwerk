import SwiftUI

/// Shown once on narrow iPhone screens (a normal iPhone, or an iPhone Duo while folded).
/// Formwerk is made for the Duo's inner screen, but it runs on every iPhone in the compact layout.
/// On a Duo, unfolding switches to the full editor by itself.
struct UnfoldView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "iphone.gen3")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(Theme.blue)
                .frame(width: 104, height: 104)
                .background(Theme.blue.opacity(0.10), in: Circle())
                .padding(.bottom, Theme.Space.xs)
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
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 320, minHeight: 34)
            }
            .formwerkGlassButton(prominent: true)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, Theme.Space.m)
        }
        .panelAppear(from: .center)
        // Comfortable line length on the unfolded or landscape screen.
        .frame(maxWidth: 440)
        .padding(.horizontal, Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
