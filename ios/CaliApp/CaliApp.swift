import Foundation
import SwiftUI

// The type is not named `CaliApp` so it does not shadow the `CaliApp` module name
// (tests use `@testable import CaliApp`).
@main
struct CaliAppMain: App {
    @State private var store = AppStore(persists: !CaliAppMain.isRunningTests && !CaliAppMain.isDebugScenario)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }

    private static var isDebugScenario: Bool {
        #if DEBUG
        DebugScenario.launch != nil
        #else
        false
        #endif
    }

    /// Unit tests are hosted in the app; keep them away from the user's local database.
    /// `XCTestConfigurationFilePath` is not set for device runs from an `.xctestrun` (Xcode 27), so also
    /// check whether XCTest was injected into the process.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
