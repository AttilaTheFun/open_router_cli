// The command line. Besides its own options the CLI takes the ones a host
// that drives Claude Code passes, so the same host drives this unchanged.
// Some of those are honoured, and some have nothing here to act on: those
// are taken, do nothing, and the CLI says so on stderr rather than let a
// host or a person think they were applied. An option that is neither is
// refused, as Claude Code refuses one it does not know: taking it would
// be pretending, and what followed it would be read as the prompt.

import Foundation

struct Options {
    var command: String?
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    /// `--max-turns`: how many rounds of tool calls a turn may take.
    var maxTurns: Int?

    static let commands: Set<String> = ["auth", "models", "sessions", "resume", "help", "version"]

    /// Options that take a value.
    static let valued: Set<String> = [
        "model", "effort", "resume", "session-id", "cwd", "input-format", "output-format", "max-turns",
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

    /// What `--input-format` and `--output-format` may be. (Claude Code's
    /// `json` output, one object at the end, is not among them.)
    static let formats: Set<String> = ["text", "stream-json"]

    /// Throws `BadOption` for an option this CLI does not take, one that
    /// needs a value and has none, a switch given one, and a value an
    /// option cannot take.
    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        if let first = rest.first, Self.commands.contains(first) {
            command = first
            rest = rest.dropFirst()
        }
        /// The value after an option, taken off the arguments.
        func value(of option: String) throws -> String {
            guard let value = rest.first else { throw BadOption(message: "\(option) needs a value") }
            rest = rest.dropFirst()
            return value
        }
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-p" || argument == "--print" { flags.insert("p"); continue }
            if argument == "-h" { flags.insert("help"); continue }
            if argument == "-m" { values["model"] = try value(of: argument); continue }
            // After "--", everything is the prompt, whatever it looks like.
            if argument == "--" { positional.append(contentsOf: rest); break }
            // A dash and a letter is an option, and not one of the three
            // above; anything else that is not "--name" is a prompt's word.
            if argument.count == 2, argument.hasPrefix("-"), argument.last?.isLetter == true {
                throw BadOption(message: "\(argument) is not an option openrouter takes")
            }
            guard argument.hasPrefix("--") else { positional.append(argument); continue }
            var name = String(argument.dropFirst(2))
            var given: String?
            if let equals = name.firstIndex(of: "=") {
                given = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if Self.valued.contains(name) {
                values[name] = try given ?? value(of: argument)
            } else if Self.switches.contains(name) {
                guard given == nil else { throw BadOption(message: "--\(name) takes no value") }
                flags.insert(name)
            } else {
                throw BadOption(message: "--\(name) is not an option openrouter takes")
            }
        }
        if let text = values["max-turns"] {
            guard let turns = Int(text), turns > 0 else { throw BadOption(message: "--max-turns takes a number above zero, not \"\(text)\"") }
            maxTurns = turns
        }
        for option in ["input-format", "output-format"] {
            if let format = values[option], !Self.formats.contains(format) {
                throw BadOption(message: "--\(option) is text or stream-json, not \"\(format)\"")
            }
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
        return notes
    }
}
