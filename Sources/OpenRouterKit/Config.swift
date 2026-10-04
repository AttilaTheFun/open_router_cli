// The CLI's configuration: where the key and the default model come from.
// Nothing here is Visor's business — a host that drives the CLI expects it
// configured already, the way `claude` and `codex` are logged in before
// anything drives them.
//
// The key: OPENROUTER_API_KEY (or OPEN_ROUTER_API_KEY) in the environment,
// else `apiKey` in ~/.openrouter/config.json (`openrouter auth login`).
// The home directory can be moved with OPENROUTER_HOME. Everything here
// takes the environment to read, the process's own unless another is
// given.

import Foundation
import System

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

    /// The environment variables a key is looked for in, in order.
    static let keyVariables = ["OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"]

    /// ~/.openrouter, or OPENROUTER_HOME.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["OPENROUTER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openrouter", isDirectory: true)
    }

    public static func file(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        directory(environment: environment).appendingPathComponent("config.json")
    }

    /// The config as it is on disk: empty when there is no file, and a
    /// throw when there is one that cannot be read as a config. What
    /// writes the file back (`auth login`, `auth logout`) reads it with
    /// this, so a file it cannot make sense of is not replaced.
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ORConfig {
        let file = file(environment: environment)
        guard FileManager.default.fileExists(atPath: file.path) else { return ORConfig() }
        return try JSONDecoder().decode(ORConfig.self, from: Data(contentsOf: file))
    }

    /// The config to run with: what is on disk, or an empty one when
    /// there is nothing there that reads as a config.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> ORConfig {
        (try? read(environment: environment)) ?? ORConfig()
    }

    /// Writes the config. The key is a secret: the file is the owner's
    /// alone from the moment it exists, made so beside its place and then
    /// moved into it, never written readable and closed up after.
    public func save(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let directory = Self.directory(environment: environment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let fresh = directory.appendingPathComponent("config.json.\(UUID().uuidString.lowercased()).new")
        do {
            // Made with its permissions, not given them after: no moment
            // at which another user could open it.
            let descriptor = try FileDescriptor.open(FilePath(fresh.path), .writeOnly, options: [.create, .exclusiveCreate], permissions: .ownerReadWrite)
            try descriptor.closeAfter { _ = try descriptor.writeAll(data) }
        } catch let errno as Errno {
            throw POSIXError(POSIXErrorCode(rawValue: errno.rawValue) ?? .EIO, userInfo: [NSFilePathErrorKey: fresh.path])
        }
        do {
            // The new file's own permissions, not those of the one it replaces.
            _ = try FileManager.default.replaceItemAt(Self.file(environment: environment), withItemAt: fresh, options: .usingNewMetadataOnly)
        } catch {
            try? FileManager.default.removeItem(at: fresh)
            throw error
        }
    }

    /// The key in a variable of the environment, and the variable's name:
    /// the first of `keyVariables` that holds more than white space.
    private static func environmentKey(_ environment: [String: String]) -> (name: String, key: String)? {
        for name in keyVariables {
            if let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty { return (name, key) }
        }
        return nil
    }

    /// The key in the config file, when it holds more than white space.
    private static func fileKey(_ environment: [String: String]) -> String? {
        guard let key = load(environment: environment).apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// The key to use: the environment first, then the config file. Nil
    /// when there is none anywhere.
    public static func resolvedKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environmentKey(environment)?.key ?? fileKey(environment)
    }

    /// Where the key `resolvedKey` gives came from, for `openrouter auth
    /// status`. Nil exactly when there is no key.
    public static func keySource(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let found = environmentKey(environment) { return "environment (\(found.name))" }
        return fileKey(environment) == nil ? nil : file(environment: environment).path
    }

    /// Where the key came from, as Claude Code's `apiKeySource` says it:
    /// the environment variable's name, or "config". Nil exactly when
    /// there is no key.
    public static func keySourceName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let found = environmentKey(environment) { return found.name }
        return fileKey(environment) == nil ? nil : "config"
    }

    /// The model to run: the one asked for, else the config's, else the default.
    public static func model(requested: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let requested, !requested.isEmpty { return requested }
        if let configured = load(environment: environment).model, !configured.isEmpty { return configured }
        return defaultModel
    }
}
