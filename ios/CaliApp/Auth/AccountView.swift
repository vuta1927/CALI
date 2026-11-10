import AuthenticationServices
import CaliCore
import SwiftUI

/// "Tài khoản" (IOS-008, docs/08 §6). The app is complete without an account; signing in only turns sync on.
/// Sign-out always offers both outcomes for the data on this phone: keep it or delete it.
struct AccountView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmSignOut = false

    var body: some View {
        let auth = store.auth
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(Self.headline(auth.state)).font(.title3.bold()).foregroundStyle(Color.caliText)
                    Text(Self.explanation(auth.state)).foregroundStyle(Color.caliSecondary)
                    if let message = auth.message {
                        Text(message).font(.subheadline).foregroundStyle(Color.caliError)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .caliCard(padding: Spacing.l)

                switch auth.state {
                case .signedOut:
                    if auth.isAvailable {
                        SignInWithAppleButton(.signIn) { auth.prepare($0) } onCompletion: { result in
                            Task { await auth.handle(result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .disabled(auth.isWorking)
                    } else {
                        Text("Bản dựng này chưa có địa chỉ máy chủ nên chưa đăng nhập được.")
                            .font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                case .choosingAttach:
                    EmptyView() // the alert below asks the question
                case .signedIn:
                    Button("Đăng xuất") { confirmSignOut = true }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Tài khoản")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Gắn dữ liệu trên máy vào tài khoản?", isPresented: .constant(auth.state == .choosingAttach)) {
            Button("Gắn vào tài khoản") { auth.chooseAttach(true) }
            Button("Chỉ giữ trên máy") { auth.chooseAttach(false) }
        } message: {
            Text("Buổi tập, giáo án, mục tiêu và số đo đang có trên iPhone này sẽ được gửi lên tài khoản, giữ nguyên từng mục. Nếu chỉ giữ trên máy, chúng không bao giờ được gửi; từ giờ trở đi thay đổi mới vẫn đồng bộ.")
        }
        .confirmationDialog("Đăng xuất?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Đăng xuất, giữ dữ liệu trên máy") { Task { await store.signOut(deleteLocalData: false) } }
            Button("Đăng xuất và xoá dữ liệu trên máy", role: .destructive) { Task { await store.signOut(deleteLocalData: true) } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(Self.signOutMessage(pending: store.sync.status.pending, workoutActive: store.activeSessionInProgress))
        }
    }

    static func headline(_ state: AuthService.State) -> String {
        switch state {
        case .signedOut: "Chưa đăng nhập"
        case .choosingAttach: "Chọn cách dùng dữ liệu trên máy"
        case let .signedIn(name): name.map { "Đã đăng nhập · \($0)" } ?? "Đã đăng nhập bằng Apple"
        }
    }

    static func explanation(_ state: AuthService.State) -> String {
        switch state {
        case .signedOut: "COAMI dùng đầy đủ mà không cần tài khoản. Đăng nhập chỉ để đồng bộ dữ liệu giữa các thiết bị. COAMI không xin tên hay e-mail từ Apple."
        case .choosingAttach: "Bạn cần chọn trước khi đồng bộ bắt đầu."
        case .signedIn: "Thay đổi trên máy được gửi lên tài khoản khi có mạng. Mọi buổi tập vẫn lưu trên máy trước."
        }
    }

    static func signOutMessage(pending: Int, workoutActive: Bool) -> String {
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) thay đổi chưa gửi sẽ mất nếu bạn xoá dữ liệu trên máy.") }
        if workoutActive { parts.append("Buổi tập đang dở cũng sẽ bị huỷ nếu bạn xoá.") }
        parts.append("Đăng xuất xong, máy này ngừng đồng bộ ngay.")
        return parts.joined(separator: " ")
    }
}
