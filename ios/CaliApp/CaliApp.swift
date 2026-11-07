import SwiftUI

// The type is not named `CaliApp` so it does not shadow the `CaliApp` module name
// (tests use `@testable import CaliApp`).
@main
struct CaliAppMain: App {
    var body: some Scene {
        WindowGroup {
            ContentView(buildInfo: .current)
        }
    }
}
