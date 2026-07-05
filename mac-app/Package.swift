// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuestMirror",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Prebuilt WebRTC.xcframework binary distribution (macOS + iOS).
        // https://github.com/stasel/WebRTC
        .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0")
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate",
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "QuestMirror",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
                "CGVirtualDisplayPrivate"
            ],
            path: "Sources/QuestMirror",
            resources: [
                .copy("Resources/web")
            ]
        )
    ]
)
