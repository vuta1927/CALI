import SwiftUI

/// Dark brand backdrop shared by the launch and welcome screens.
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
/// It never waits on the network: the catalog refresh starts after it is gone.
struct LaunchView: View {
    var body: some View {
        ZStack {
            BrandBackdrop()
            VStack(spacing: Spacing.m) {
                COAMISymbol()
                    .frame(width: 96, height: 96)
                Text("COAMI")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(Color.coamiCream)
                ProgressView()
                    .tint(Color.coamiCream)
                    .padding(.top, Spacing.l)
                    .accessibilityLabel("Đang chuẩn bị")
            }
        }
        .preferredColorScheme(.dark)
    }
}
