import SwiftUI

// The type is not named `CaliApp` so it does not shadow the `CaliApp` module name
// (tests use `@testable import CaliApp`).
@main
struct CaliAppMain: App {
    @State private var store = AppStore(persists: !CaliAppMain.isRunningTests)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }

    /// Unit tests are hosted in the app; keep them away from the user's local data file.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
