import SwiftUI

/// Dark brand backdrop used by the welcome screen.
struct BrandBackdrop: View {
    var body: some View {
        ZStack {
            Color.coamiInk
            RadialGradient(colors: [Color.coamiOrange.opacity(0.55), .clear], center: .top, startRadius: 0, endRadius: 520)
            LinearGradient(colors: [.clear, Color.coamiInk.opacity(0.9)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Shown on every launch while the app restores its stored session and cached settings.
/// Same artwork and background as the system launch screen (`UILaunchScreen`), so the hand-off does not jump.
/// It never waits on the network: the catalog refresh starts after it is gone.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Color("COAMIBackground")
                .ignoresSafeArea()
            Image("COAMILaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .padding(.horizontal, Spacing.xl)
                .accessibilityLabel("COAMI")
        }
    }
}
