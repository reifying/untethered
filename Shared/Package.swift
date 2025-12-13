// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VoiceCodeShared",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VoiceCodeShared",
            targets: ["VoiceCodeShared"]
        ),
    ],
    targets: [
        .target(
            name: "VoiceCodeShared"
            // Resources will be added when CoreData model is moved:
            // resources: [.process("CoreData/VoiceCode.xcdatamodeld")]
        ),
        .testTarget(
            name: "VoiceCodeSharedTests",
            dependencies: ["VoiceCodeShared"]
        ),
    ]
)
