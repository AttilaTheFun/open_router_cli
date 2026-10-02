// The command line. Besides its own options the CLI takes the ones a host
// that drives Claude Code passes, so the same host drives this unchanged.
// Some of those are honoured, and some have nothing here to act on: those
// are taken, do nothing, and the CLI says so on stderr rather than let a
// host or a person think they were applied.

import Foundation

struct Options {
    var command: String?
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    /// Options that are not this CLI's nor among Claude Code's it knows,
    /// as given. Each is taken as a switch and ignored.
    var unknown: [String] = []
    /// `--max-turns`: how many rounds of tool calls a turn may take.
    var maxTurns: Int?

    static let commands: Set<String> = ["auth", "models", "sessions", "resume", "help", "version"]

    /// Options that take a value.
    static let valued: Set<String> = [
        "model", "effort", "resume", "session-id", "cwd", "input-format", "output-format", "max-turns", "key",
        // Claude Code's, taken and not acted on (see `notes`).
        "permission-mode", "permission-prompt-tool", "mcp-config",
    ]

    /// Options that are switches.
    static let switches: Set<String> = [
        "help", "version", "include-partial-messages", "json", "free", "tools", "refresh",
        // Claude Code's, with nothing to change here: stream-json output is
        // always whole (`--verbose`), and tools already run without asking
        // (`--dangerously-skip-permissions`).
        "verbose", "dangerously-skip-permissions",
    ]

    /// Throws `BadOption` for an option that needs a value and has none,
    /// or has one it cannot take.
    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        if let first = rest.first, Self.commands.contains(first) {
            command = first
            rest = rest.dropFirst()
        }
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-p" || argument == "--print" { flags.insert("p"); continue }
            if argument == "-h" { flags.insert("help"); continue }
            if argument == "-m", let value = rest.first { values["model"] = value; rest = rest.dropFirst(); continue }
            guard argument.hasPrefix("--") else { positional.append(argument); continue }
            let name = String(argument.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                let key = String(name[..<equals])
                values[key] = String(name[name.index(after: equals)...])
                if !Self.valued.contains(key) { unknown.append("--" + key) }
            } else if Self.valued.contains(name) {
                guard let value = rest.first else { throw BadOption(message: "\(argument) needs a value") }
                values[name] = value
                rest = rest.dropFirst()
            } else {
                flags.insert(name)
                if !Self.switches.contains(name) { unknown.append(argument) }
            }
        }
        if let text = values["max-turns"] {
            guard let turns = Int(text), turns > 0 else { throw BadOption(message: "--max-turns takes a number above zero, not \"\(text)\"") }
            maxTurns = turns
        }
    }

    struct BadOption: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// What to say about the options given that will not do what their
    /// names say. The agent has one way of working — its tools run without
    /// asking, and it has the coding tools and no others — so Claude
    /// Code's options for permissions and MCP servers have nothing to
    /// change; they are taken so that a host's command line works, and
    /// named here so that nobody takes them for applied.
    var notes: [String] {
        var notes: [String] = []
        if let mode = values["permission-mode"], mode != "bypassPermissions" {
            notes.append("--permission-mode \(mode) is not enforced: openrouter has one mode, and in it tools run without asking.")
        }
        if let tool = values["permission-prompt-tool"] {
            notes.append("--permission-prompt-tool is not used: openrouter's tools run without asking, and \(tool) is never asked.")
        }
        if values["mcp-config"] != nil {
            notes.append("--mcp-config is not used: openrouter does not connect to MCP servers, and the model is not offered their tools.")
        }
        for option in unknown {
            notes.append("\(option) is not an option openrouter knows; it is ignored.")
        }
        return notes
    }
}
