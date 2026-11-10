import SwiftUI
import UIKit

/// Exercise identity image (AGENTS rule 2: visual-first).
///
/// A server poster (downloaded and kept by `ExerciseMediaCache`, BE-006) or the user's own photo overlays the labeled
/// fallback. An exercise the server has no published poster for still shows the placeholder.
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
            if let media = exercise?.poster, let url = media.url {
                GeometryReader { geometry in
                    if media.source == .local, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: height).clipped()
                    } else if media.source == .remote {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: height).clipped()
                            }
                        }
                    }
                }
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
        .accessibilityLabel("\(exercise?.name ?? "Bài tập"), ảnh bài tập")
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
