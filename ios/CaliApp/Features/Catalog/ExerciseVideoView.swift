import AVKit
import SwiftUI

struct ExerciseVideoView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading) {
            VideoPlayer(player: player).frame(height: 220)
            Text("Nhấn phát để xem. Nếu video không tải được, bạn vẫn có thể tập với ảnh và hướng dẫn.")
                .font(.footnote).foregroundStyle(Color.caliSecondary)
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear { player?.pause(); player = nil }
    }
}
