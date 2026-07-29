// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClipDeck",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClipDeck", targets: ["ClipDeck"])
    ],
    targets: [
        .executableTarget(
            name: "ClipDeck"
        ),
        .testTarget(
            name: "ClipDeckTests",
            dependencies: ["ClipDeck"]
        )
    ]
)
