import SwiftUI

/// I0 placeholder screen: proves the sideloaded build launches and shows which commit it is.
struct ContentView: View {
    let buildInfo: BuildInfo

    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: "CALI")
                .font(.largeTitle.bold())
            Text(verbatim: "Version \(buildInfo.version) (\(buildInfo.build))")
                .font(.body)
            Text(verbatim: "Build \(buildInfo.sha)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
