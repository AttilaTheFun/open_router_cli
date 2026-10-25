// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "open_router_cli",
    // macOS and Linux: the bash tool runs a process, and the config and
    // the sessions live in the user's home folder; the iOS SDK has neither
    // `posix_spawn` nor `homeDirectoryForCurrentUser`. macOS 15 for `Mutex`.
    platforms: [.macOS(.v15)],
    products: [
        // The library: the API client, the agent loop, the coding tools,
        // sessions on disk, the config, and Claude Code's stream-json
        // protocol. A host can embed it without the CLI.
        .library(name: "OpenRouterKit", targets: ["OpenRouterKit"]),
        // The CLI: a coding agent in the terminal, and the headless mode
        // Visor drives.
        .executable(name: "openrouter", targets: ["openrouter"]),
    ],
    dependencies: [
        // File descriptors and their errors on Linux as on macOS (the
        // system's own `System` is Apple's alone).
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
    ],
    targets: [
        .target(name: "OpenRouterKit", dependencies: [.product(name: "SystemPackage", package: "swift-system")]),
        .executableTarget(name: "openrouter", dependencies: ["OpenRouterKit"]),
        // What both test targets use: the mock transport, so no test
        // reaches the network.
        .target(name: "TestSupport", dependencies: ["OpenRouterKit"], path: "Tests/TestSupport"),
        .testTarget(name: "OpenRouterKitTests", dependencies: ["OpenRouterKit", "TestSupport"]),
        .testTarget(name: "OpenRouterCLITests", dependencies: ["openrouter", "OpenRouterKit", "TestSupport"]),
    ]
)
