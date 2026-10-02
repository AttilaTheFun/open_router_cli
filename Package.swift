// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "open_router_cli",
    // macOS only: the bash tool runs a process, and the config and the
    // sessions live in the user's home folder; the iOS SDK has neither
    // `Process` nor `homeDirectoryForCurrentUser`.
    platforms: [.macOS(.v13)],
    products: [
        // The library: the API client, the agent loop, the coding tools,
        // sessions on disk, the config, and Claude Code's stream-json
        // protocol. A host can embed it without the CLI.
        .library(name: "OpenRouterKit", targets: ["OpenRouterKit"]),
        // The CLI: a coding agent in the terminal, and the headless mode
        // Visor drives.
        .executable(name: "openrouter", targets: ["openrouter"]),
    ],
    targets: [
        .target(name: "OpenRouterKit"),
        .executableTarget(name: "openrouter", dependencies: ["OpenRouterKit"]),
        .testTarget(name: "OpenRouterKitTests", dependencies: ["OpenRouterKit"]),
    ]
)
