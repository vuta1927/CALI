import SwiftUI

/// First-launch welcome (Strava-style): full-bleed brand screen, a swipeable value carousel and two actions.
/// Nothing here requires an account or the network; signing in only turns sync on.
struct WelcomeView: View {
    let showsSignIn: Bool
    let onContinue: () -> Void
    let onSignIn: () -> Void

    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let slides: [WelcomeSlide] = [
        .init(systemImage: "figure.strengthtraining.functional", title: "Tập rõ ràng. Tiến bộ bền vững.",
              text: "Giáo án, hướng dẫn trực quan đến từng set và khoảng nghỉ — gọn trong một ứng dụng."),
        .init(systemImage: "wifi.slash", title: "Tập được cả khi offline",
              text: "Mọi buổi tập lưu trên iPhone trước. Có mạng và đăng nhập thì dữ liệu mới đồng bộ."),
        .init(systemImage: "cross.case", title: "An toàn là trên hết",
              text: "COAMI không đưa ra lời khuyên y tế. Dừng tập nếu thấy đau và hỏi chuyên gia khi cần."),
    ]

    var body: some View {
        BrandBackdrop()
        .overlay {
            VStack(spacing: 0) {
                VStack(spacing: Spacing.m) {
                    COAMISymbol()
                        .frame(width: 96, height: 96)
                    Text("COAMI")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(Color.coamiCream)
                }
                .padding(.top, 72)
                .accessibilityElement(children: .combine)

                Spacer(minLength: Spacing.xl)

                TabView(selection: $page) {
                    ForEach(Array(Self.slides.enumerated()), id: \.offset) { index, slide in
                        VStack(spacing: Spacing.m) {
                            Image(systemName: slide.systemImage)
                                .font(.title)
                                .foregroundStyle(Color.coamiFlame)
                                .accessibilityHidden(true)
                            Text(slide.title)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.coamiCream)
                            Text(slide.text)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.coamiCream.opacity(0.78))
                        }
                        .padding(.horizontal, Spacing.xl)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .never))
                .frame(height: 240)
                .animation(reduceMotion ? nil : .default, value: page)

                VStack(spacing: Spacing.m) {
                    Button("Bắt đầu", action: onContinue)
                        .buttonStyle(.caliPrimary)
                    if showsSignIn {
                        Button(action: onSignIn) {
                            Text("Đã có tài khoản? Đăng nhập")
                                .font(.headline)
                                .foregroundStyle(Color.coamiCream)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.l)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct WelcomeSlide {
    let systemImage: String
    let title: String
    let text: String
}
