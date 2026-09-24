// openrouter: a coding agent on OpenRouter's models, in the terminal and
// headless. Configured on its own (`openrouter auth login`), the way
// `claude` and `codex` are; a host such as Visor only runs it.
//
//   openrouter [--model M] [--effort E] [--resume ID] [--cwd DIR]     chat here
//   openrouter resume ID                                              carry a session on
//   openrouter -p [PROMPT] [--output-format text|stream-json]         one turn, headless
//   openrouter -p --input-format stream-json --output-format stream-json --include-partial-messages
//                                                                     Claude Code's protocol on stdin/stdout
//   openrouter auth status | login [KEY] | logout
//   openrouter models [--free] [--tools] [--json]
//   openrouter sessions [--cwd DIR] [--json]

import Foundation
import OpenRouterKit

let version = "0.2.0"

struct Options {
    var command: String?
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    /// Flags that take a value; any other `--flag` is a switch (and an
    /// unknown one is ignored, so a host's extra flags do no harm).
    static let valued: Set<String> = ["model", "effort", "resume", "session-id", "cwd", "input-format", "output-format",
                                      "permission-mode", "mcp-config", "permission-prompt-tool", "max-turns", "key"]

    init(_ arguments: [String]) {
        var rest = arguments[...]
        if let first = rest.first, !first.hasPrefix("-"), ["auth", "models", "sessions", "resume", "help", "version"].contains(first) {
            command = first
            rest = rest.dropFirst()
        }
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument == "-p" || argument == "--print" { flags.insert("p"); continue }
            if argument == "-m", let value = rest.first { values["model"] = value; rest = rest.dropFirst(); continue }
            guard argument.hasPrefix("--") else { positional.append(argument); continue }
            let name = String(argument.dropFirst(2))
            if let equals = name.firstIndex(of: "=") {
                values[String(name[..<equals])] = String(name[name.index(after: equals)...])
            } else if Self.valued.contains(name), let value = rest.first {
                values[name] = value
                rest = rest.dropFirst()
            } else {
                flags.insert(name)
            }
        }
    }
}

let options = Options(Array(CommandLine.arguments.dropFirst()))

func usage() {
    Output.line("""
        openrouter \(version) — a coding agent on OpenRouter's models
          openrouter [--model M] [--effort E] [--resume ID] [--cwd DIR]   chat in this folder
          openrouter resume ID                                            carry a session on
          openrouter -p [PROMPT] [--output-format text|stream-json]       one turn, headless
          openrouter -p --input-format stream-json --output-format stream-json --include-partial-messages
                                                                          Claude Code's stream-json protocol on stdin/stdout
          openrouter auth status | login [KEY] | logout                   the key (or OPENROUTER_API_KEY)
          openrouter models [--free] [--tools] [--json] [--refresh]       what OpenRouter offers (kept in ~/.openrouter/models.json)
          openrouter sessions [--cwd DIR] [--json]                        sessions kept in ~/.openrouter/sessions
        Config: ~/.openrouter/config.json ({"apiKey": …, "model": …}); OPENROUTER_HOME moves it.
        """)
}

func readSecret(prompt: String) -> String {
    Output.text(prompt)
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    var quiet = term
    quiet.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &term); Output.text("\n") }
    return readLine() ?? ""
}

func auth(_ subcommand: String?, _ rest: [String]) async -> Int32 {
    switch subcommand {
    case "login":
        var key = rest.first ?? options.values["key"] ?? ""
        if key.isEmpty { key = readSecret(prompt: "OpenRouter API key (https://openrouter.ai/keys): ") }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-or-") else { Output.error("That does not look like an OpenRouter key (they start with sk-or-)."); return 1 }
        let client = OpenRouterClient(apiKey: key)
        do { _ = try await client.models() } catch { Output.error("OpenRouter rejected the key: \(error.localizedDescription)"); return 1 }
        var config = ORConfig.load()
        config.apiKey = key
        do { try config.save() } catch { Output.error("Could not save \(ORConfig.file.path): \(error.localizedDescription)"); return 1 }
        Output.line("Saved to \(ORConfig.file.path)")
        return 0
    case "logout":
        var config = ORConfig.load()
        config.apiKey = nil
        do { try config.save() } catch { Output.error("Could not save \(ORConfig.file.path): \(error.localizedDescription)"); return 1 }
        Output.line("Key removed from \(ORConfig.file.path)")
        return 0
    case "status", nil:
        if let source = ORConfig.keySource() {
            Output.line("Logged in: key from \(source)")
            Output.line("Model: \(ORConfig.model(requested: nil))")
            return 0
        }
        Output.line("Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY.")
        return 1
    default:
        Output.error("openrouter auth status | login [KEY] | logout")
        return 2
    }
}

func models() async -> Int32 {
    let client = OpenRouterClient()
    guard client.hasKey else { Output.error("Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY."); return 1 }
    do {
        // The list is kept on disk for hosts to read; asked for, it is
        // fetched afresh and kept again.
        var list = try await ORModelCache.refresh(client: client)
        if options.flags.contains("refresh") { Output.line("Kept \(list.count) models in \(ORModelCache.file.path)"); return 0 }
        if options.flags.contains("free") { list = list.filter { $0.id.hasSuffix(":free") } }
        if options.flags.contains("tools") { list = list.filter { $0.supportsTools } }
        if options.flags.contains("json") {
            let data = try JSONEncoder().encode(list)
            Output.line(String(decoding: data, as: UTF8.self))
        } else {
            for model in list {
                let price = model.pricePerMillion.map { model.isFree ? "  free" : String(format: "  $%.2f/$%.2f per M", $0.input, $0.output) } ?? ""
                Output.line(model.id + (model.contextLength.map { "  (\($0) ctx)" } ?? "") + (model.supportsTools ? "  tools" : "") + price)
            }
        }
        return 0
    } catch {
        Output.error("\(error.localizedDescription)")
        return 1
    }
}

func sessions() -> Int32 {
    let list = ORSessionStore().list(cwd: options.values["cwd"])
    if options.flags.contains("json") {
        struct Row: Encodable { let id: String; let cwd: String; let model: String; let title: String; let updated: Double }
        let rows = list.map { Row(id: $0.id, cwd: $0.cwd, model: $0.model, title: $0.title, updated: $0.updated) }
        if let data = try? JSONEncoder().encode(rows) { Output.line(String(decoding: data, as: UTF8.self)) }
        return 0
    }
    for session in list {
        let when = Date(timeIntervalSince1970: session.updated).formatted(date: .abbreviated, time: .shortened)
        Output.line("\(session.id)  \(when)  \(session.cwd)  \(session.title)")
    }
    if list.isEmpty { Output.line("No sessions yet.") }
    return 0
}

/// The headless mode: one prompt, or Claude Code's stream-json on stdin.
func headless() async -> Int32 {
    let streamIn = options.values["input-format"] == "stream-json"
    let streamOut = options.values["output-format"] == "stream-json"
    let conversation: Conversation
    do {
        conversation = try Conversation(resume: options.values["resume"], sessionID: options.values["session-id"],
                                        cwd: options.values["cwd"] ?? FileManager.default.currentDirectoryPath,
                                        model: options.values["model"], effort: options.values["effort"])
    } catch {
        let message = "Could not open the session: \(error.localizedDescription)"
        if streamOut { Output.line(StreamJSON.result(isError: true, text: message, sessionID: options.values["resume"] ?? "")) } else { Output.error(message) }
        return 1
    }
    if streamOut {
        Output.line(StreamJSON.systemInit(sessionID: conversation.session.id, model: conversation.model, cwd: conversation.cwd,
                                          tools: CodingTools.standard(cwd: conversation.cwd).map(\.name)))
    }
    // A host reads the model list from disk; keep it no older than a day.
    if ORModelCache.isStale, conversation.hasKey { Task.detached { _ = try? await ORModelCache.refresh() } }
    let runner = HeadlessRunner(conversation: conversation, streamOut: streamOut)
    if streamIn {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let input = StreamJSON.parse(line) else { continue }
                switch input {
                case .user(let text): await runner.enqueue(text)
                case .interrupt(let requestID):
                    await runner.interrupt()
                    if streamOut { Output.line(StreamJSON.controlResponse(requestID: requestID)) }
                }
            }
        } catch {
            Output.error("stdin: \(error.localizedDescription)")
        }
        await runner.drain()
        return 0
    }
    var prompt = options.positional.joined(separator: " ")
    if prompt.isEmpty, let data = try? FileHandle.standardInput.readToEnd() {
        prompt = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !prompt.isEmpty else { Output.error("Nothing to say: give a prompt, or pipe one in."); return 2 }
    await runner.enqueue(prompt)
    await runner.drain()
    return 0
}

/// The terminal chat: type, watch the reply stream, see the tools run.
func chat(resume: String?) async -> Int32 {
    let conversation: Conversation
    do {
        conversation = try Conversation(resume: resume, sessionID: options.values["session-id"],
                                        cwd: options.values["cwd"] ?? FileManager.default.currentDirectoryPath,
                                        model: options.values["model"], effort: options.values["effort"])
    } catch {
        Output.error("Could not open the session: \(error.localizedDescription)")
        return 1
    }
    guard conversation.hasKey else {
        Output.error("Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY.")
        return 1
    }
    Output.line("openrouter \(version) · \(conversation.model) · \(conversation.cwd)")
    Output.line("session \(conversation.session.id) · /model <id> to switch · Ctrl-D to quit")
    while true {
        Output.text("\n\u{203A} ")
        guard let entered = readLine() else { Output.text("\n"); break }
        let text = entered.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        if text.hasPrefix("/model ") {
            conversation.setModel(String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            conversation.save()
            Output.line("model: \(conversation.model)")
            continue
        }
        if text == "/quit" || text == "/exit" { break }
        do {
            try await conversation.run(text) { event in
                switch event {
                case .delta(let piece): Output.text(piece)
                case .toolCall(let name, let arguments, _):
                    let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
                    let summary = (object?["command"] ?? object?["path"]) as? String ?? ""
                    Output.text("\n[\(name)] \(summary)\n")
                case .toolResult(_, let output, _):
                    let first = output.split(separator: "\n").prefix(3).joined(separator: "\n")
                    Output.text("  \(first.replacingOccurrences(of: "\n", with: "\n  "))\n")
                case .done: Output.text("\n")
                case .message, .assistant, .usage: break
                }
            }
        } catch {
            Output.error("\n\(error.localizedDescription)")
        }
    }
    return 0
}

if options.flags.contains("version") || options.command == "version" { Output.line(version); exit(0) }
if options.flags.contains("help") || options.flags.contains("h") || options.command == "help" { usage(); exit(0) }

let status: Int32
switch options.command {
case "auth": status = await auth(options.positional.first, Array(options.positional.dropFirst()))
case "models": status = await models()
case "sessions": status = sessions()
case "resume": status = await chat(resume: options.positional.first)
default: status = options.flags.contains("p") ? await headless() : await chat(resume: options.values["resume"])
}
exit(status)
