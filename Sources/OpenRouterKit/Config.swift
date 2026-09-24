// The CLI's configuration: where the key and the default model come from.
// Nothing here is Visor's business — a host that drives the CLI expects it
// configured already, the way `claude` and `codex` are logged in before
// anything drives them.
//
// The key: OPENROUTER_API_KEY (or OPEN_ROUTER_API_KEY) in the environment,
// else `apiKey` in ~/.openrouter/config.json (`openrouter auth login`).
// The home directory can be moved with OPENROUTER_HOME.

import Foundation

public struct ORConfig: Codable, Sendable, Equatable {
    public var apiKey: String?
    /// The model used when none is asked for.
    public var model: String?

    public init(apiKey: String? = nil, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model
    }

    /// The model when neither the caller nor the config names one: cheap,
    /// quick, and able to call tools.
    public static let defaultModel = "openai/gpt-5-nano"

    /// ~/.openrouter, or OPENROUTER_HOME.
    public static var directory: URL {
        if let home = ProcessInfo.processInfo.environment["OPENROUTER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openrouter", isDirectory: true)
    }

    public static var file: URL { directory.appendingPathComponent("config.json") }

    public static func load() -> ORConfig {
        guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(ORConfig.self, from: data) else {
            return ORConfig()
        }
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
        // The key is a secret: owner-only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    /// The key to use: the environment first, then the config file. Nil
    /// when there is none anywhere.
    public static func resolvedKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for name in ["OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"] {
            if let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        }
        if let key = load().apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return key }
        return nil
    }

    /// Where the key came from, for `openrouter auth status`.
    public static func keySource(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for name in ["OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"] where !(environment[name] ?? "").isEmpty { return "environment (\(name))" }
        if !(load().apiKey ?? "").isEmpty { return file.path }
        return nil
    }

    /// The model to run: the one asked for, else the config's, else the default.
    public static func model(requested: String?) -> String {
        if let requested, !requested.isEmpty { return requested }
        if let configured = load().model, !configured.isEmpty { return configured }
        return defaultModel
    }
}
