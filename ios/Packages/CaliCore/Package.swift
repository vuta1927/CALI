// swift-tools-version: 6.0
// CaliCore — local persistence + single-writer workout coordinator (docs/03 §6, docs/16, ADR-013).
// Foundation + GRDB only (no UIKit/ActivityKit/AppIntents) so it builds and tests on Linux.
// Linux needs the SQLite headers: `apt-get install libsqlite3-dev` (see README.md).
import PackageDescription

let package = Package(
    name: "CaliCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CaliCore", targets: ["CaliCore"]),
    ],
    dependencies: [
        // Pinned exactly; keep in sync with `packages.GRDB.exactVersion` in ios/project.yml.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0"),
        .package(path: "../CaliDomain"),
    ],
    targets: [
        .target(
            name: "CaliCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CaliDomain", package: "CaliDomain"),
            ]
        ),
        .testTarget(
            name: "CaliCoreTests",
            dependencies: [
                "CaliCore",
                .product(name: "CaliDomain", package: "CaliDomain"),
                .product(name: "CaliDomainTestSupport", package: "CaliDomain"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
