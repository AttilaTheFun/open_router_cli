// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "open_router_cli",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        // The library: the API client, the agent loop, the coding tools,
        // sessions on disk, the config, and Claude Code's stream-json
        // protocol. Shared by Visor and the Universal UI Playground.
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
