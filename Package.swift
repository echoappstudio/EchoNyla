// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EchoNyla",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EchoNylaCore", targets: ["EchoNylaCore"]),
        .executable(name: "EchoNyla", targets: ["EchoNylaApp"])
    ],
    dependencies: [
        // Automatic updates. Pinned exactly; the packaged app embeds this framework.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "EchoNylaCore"),
        .executableTarget(
            name: "EchoNylaApp",
            dependencies: [
                "EchoNylaCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/EchoNylaApp",
            linkerSettings: [
                // The packaged app keeps Sparkle.framework in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "EchoNylaCoreTests", dependencies: ["EchoNylaCore"])
    ],
    swiftLanguageModes: [.v5]
)
