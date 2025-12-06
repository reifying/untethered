// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "UntetheredCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "UntetheredCore",
            targets: ["UntetheredCore"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "UntetheredCore",
            dependencies: [],
            resources: [
                .process("Persistence/VoiceCode.xcdatamodeld")
            ]
        ),
        .testTarget(
            name: "UntetheredCoreTests",
            dependencies: ["UntetheredCore"]
        )
    ]
)
