// swift-tools-version: 6.0
// CaliDomain — pure Swift workout domain (ADR-012 proposal).
// Foundation only: no SwiftUI/UIKit/GRDB/ActivityKit/Combine, so it builds and tests on Linux.
import PackageDescription

let package = Package(
    name: "CaliDomain",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CaliDomain", targets: ["CaliDomain"]),
        .library(name: "CaliDomainTestSupport", targets: ["CaliDomainTestSupport"]),
    ],
    targets: [
        .target(name: "CaliDomain"),
        .target(
            name: "CaliDomainTestSupport",
            dependencies: ["CaliDomain"]
        ),
        .testTarget(
            name: "CaliDomainTests",
            dependencies: ["CaliDomain", "CaliDomainTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
