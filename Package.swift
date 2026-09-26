// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lithium",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.0"),
        .package(url: "https://github.com/ameshkov/swift-psl", "1.1.0"..<"2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Lithium",
            dependencies: [
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
                .process("Resources/Scripts"),
            ]
        ),
        .testTarget(name: "LithiumTests", dependencies: ["Lithium"]),
    ]
)
