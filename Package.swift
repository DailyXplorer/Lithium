// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lithium",
    platforms: [.macOS("15.4")],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.0"),
        .package(url: "https://github.com/ameshkov/swift-psl", "1.1.0"..<"2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Lithium",
            dependencies: [
                "LithiumProcess",
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib"),
                .product(name: "PublicSuffixList", package: "swift-psl"),
            ],
            path: "Sources/Lithium",
            resources: [
                .copy("Resources/Filters"),
                .copy("Resources/FilterSources.json"),
                .process("Resources/Fonts"),
                .process("Resources/Icons"),
                .copy("Resources/Pages"),
                .copy("Resources/SpaceIcons.tsv"),
                .process("Resources/Scripts"),
            ]
        ),
        // The stdio bridge agents start (`claude mcp add lithium -- …/lithium-mcp`), shipped in the app.
        .executableTarget(name: "lithium-mcp", dependencies: ["LithiumProcess"], path: "Sources/LithiumMCP"),
        // Tells the Lithium that wrote the endpoint file from a process that took its pid since.
        .target(name: "LithiumProcess", path: "Sources/LithiumProcess"),
        // Loaded with the tests, before any runs: NSWorkspace opens nothing in the test process.
        .target(name: "LithiumTestGuard", path: "Tests/LithiumTestGuard", linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "LithiumTests", dependencies: ["Lithium", "LithiumProcess", "LithiumTestGuard"], resources: [.copy("Fixtures")]),
    ]
)
