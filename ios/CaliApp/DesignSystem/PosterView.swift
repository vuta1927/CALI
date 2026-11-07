import SwiftUI

/// Exercise identity image (AGENTS rule 2: visual-first).
///
/// The POC has no licensed media yet, so every poster is a generated placeholder: a gradient,
/// an SF Symbol and a visible "PLACEHOLDER" label. Real posters/videos come from the
/// Exercise Catalog media pipeline (docs/06). TODO(POC-002): replace with cached catalog media.
struct PosterView: View {
    let exercise: Exercise?
    var height: CGFloat = 180
    var cornerRadius: CGFloat = Radius.card
    var showsLabel = true

    var body: some View {
        let colors = PosterPalette.colors(exercise?.paletteIndex ?? 7)
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: exercise?.symbol ?? "figure.strengthtraining.functional")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(0.9))
                .padding(height * 0.18)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            if showsLabel && height >= 90 {
                VStack {
                    HStack {
                        Spacer()
                        Text(verbatim: "PLACEHOLDER")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                    Spacer()
                }
                .padding(Spacing.s)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel("\(exercise?.name ?? "Bài tập"), ảnh minh hoạ tạm")
    }
}

/// Square thumbnail for list rows.
struct PosterThumb: View {
    let exercise: Exercise?
    var size: CGFloat = 64

    var body: some View {
        PosterView(exercise: exercise, height: size, cornerRadius: 12, showsLabel: false)
            .frame(width: size, height: size)
    }
}
