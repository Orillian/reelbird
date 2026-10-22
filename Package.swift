// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Reelbird",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "ReelbirdApp", targets: ["ReelbirdApp"]),
        .executable(name: "reelbird", targets: ["ReelbirdCLI"]),
        .library(name: "ReelbirdCore", targets: ["ReelbirdCore"]),
    ],
    targets: [
        // Pure Swift: project format, edit document, events, timeline maths. No AppKit.
        .target(name: "ReelbirdCore", swiftSettings: strict),
        // ScreenCaptureKit, camera, audio, input events, segmented writers, health checks.
        .target(name: "ReelbirdCapture", dependencies: ["ReelbirdCore"], swiftSettings: strict),
        // Metal compositor, preview playback, export.
        .target(name: "ReelbirdRender", dependencies: ["ReelbirdCore"], swiftSettings: strict),
        // S3-compatible upload, HLS playlists, static viewer page.
        .target(name: "ReelbirdShare", dependencies: ["ReelbirdCore"], swiftSettings: strict),
        // On-device captions, titles, chapters, silence detection.
        .target(name: "ReelbirdAI", dependencies: ["ReelbirdCore"], swiftSettings: strict),
        // Step guides: steps, step images, guide exports and what a link publishes with them.
        .target(name: "ReelbirdGuide", dependencies: ["ReelbirdCore", "ReelbirdRender", "ReelbirdShare", "ReelbirdAI"], swiftSettings: strict),
        // The Mac app.
        .executableTarget(
            name: "ReelbirdApp",
            dependencies: ["ReelbirdCore", "ReelbirdCapture", "ReelbirdRender", "ReelbirdShare", "ReelbirdAI", "ReelbirdGuide"],
            swiftSettings: strict
        ),
        // The `reelbird` command line tool and MCP server.
        .executableTarget(
            name: "ReelbirdCLI",
            dependencies: ["ReelbirdCore", "ReelbirdCapture", "ReelbirdRender", "ReelbirdShare", "ReelbirdAI", "ReelbirdGuide"],
            swiftSettings: strict
        ),
        .testTarget(name: "ReelbirdCoreTests", dependencies: ["ReelbirdCore"], swiftSettings: strict),
        .testTarget(name: "ReelbirdCaptureTests", dependencies: ["ReelbirdCapture"], swiftSettings: strict),
        .testTarget(name: "ReelbirdRenderTests", dependencies: ["ReelbirdRender", "ReelbirdGuide"], swiftSettings: strict),
        .testTarget(name: "ReelbirdShareTests", dependencies: ["ReelbirdShare"], swiftSettings: strict),
        .testTarget(name: "ReelbirdAITests", dependencies: ["ReelbirdAI"], swiftSettings: strict),
    ]
)
