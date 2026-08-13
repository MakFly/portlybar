// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortlyBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortlyBarCore", targets: ["PortlyBarCore"]),
        .library(name: "PortlyBarRuntime", targets: ["PortlyBarRuntime"]),
        .executable(name: "PortlyBarApp", targets: ["PortlyBarApp"]),
        .executable(name: "portlybar", targets: ["PortlyBarCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.15.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .target(
            name: "PortlyBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PortlyBarRuntime",
            dependencies: [
                "PortlyBarCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyBarApp",
            dependencies: [
                "PortlyBarCore",
                "PortlyBarRuntime",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PortlyBarCLI",
            dependencies: [
                "PortlyBarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortlyBarCoreTests",
            dependencies: ["PortlyBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PortlyBarRuntimeTests",
            dependencies: ["PortlyBarCore", "PortlyBarRuntime"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
