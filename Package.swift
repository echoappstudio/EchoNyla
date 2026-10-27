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
        // The on-device model runs on the official llama.cpp engine (MIT), pinned to a release that
        // runs Ternary Bonsai 2 (its Q2_0 files and Hadamard transforms). The packaged app embeds it.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11800/llama-b11800-xcframework.zip",
            checksum: "9012dad52cd409de2411411292f7941c08d919639b7aa118baf7c65bed6b1fad"
        ),
        // Downloading, loading and asking the on-device model. A library, so the CI model check can use it too.
        .target(
            name: "EchoNylaEngine",
            dependencies: ["EchoNylaCore", "llama"]
        ),
        .executableTarget(
            name: "EchoNylaModelCheck",
            dependencies: ["EchoNylaCore", "EchoNylaEngine"],
            path: "Tools/ModelCheck"
        ),
        .executableTarget(
            name: "EchoNylaApp",
            dependencies: [
                "EchoNylaCore",
                "EchoNylaEngine",
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
