// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipDeck",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClipDeck", targets: ["ClipDeck"])
    ],
    targets: [
        .executableTarget(
            name: "ClipDeck",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ClipDeckTests",
            dependencies: ["ClipDeck"]
        )
    ]
)
