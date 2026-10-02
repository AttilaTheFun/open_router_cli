// openrouter: a coding agent on OpenRouter's models, in the terminal and
// headless. Configured on its own (`openrouter auth login`), the way
// `claude` and `codex` are; a host such as Visor only runs it. `usage()`
// below lists the commands and options; Options.swift says which of
// Claude Code's options are taken and not acted on.

import Foundation
import OpenRouterKit

let version = "0.3.0"

let output = Output.standard
let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    output.error("openrouter: \(error.localizedDescription) (openrouter --help lists the options)")
    exit(2)
}

func usage() {
    output.line("""
        openrouter \(version) — a coding agent on OpenRouter's models
          openrouter [--model M] [--effort E] [--resume ID] [--cwd DIR]   chat in this folder
          openrouter resume ID                                            carry a session on
          openrouter -p [PROMPT] [--output-format text|stream-json]       one turn, headless (exits 1 if it fails)
          openrouter -p --input-format stream-json --output-format stream-json --include-partial-messages
                                                                          Claude Code's stream-json protocol on stdin/stdout
          openrouter auth status | login [KEY] | logout                   the key (or OPENROUTER_API_KEY)
          openrouter models [--free] [--tools] [--json] [--refresh]       what OpenRouter offers (kept in ~/.openrouter/models.json)
          openrouter sessions [--cwd DIR] [--json]                        sessions kept in ~/.openrouter/sessions
          openrouter help | version                                       this; the version (also --help, -h, --version)
        Options:
          -p, --print                  headless: run the turn and exit
          --model M, -m M              the model (default: the config's, else \(ORConfig.defaultModel))
          --effort low|medium|high     reasoning effort, for models that take one (xhigh and max read as high)
          --resume ID                  carry a session on, in the folder it was working in
          --session-id ID              the id a new session gets
          --cwd DIR                    the folder to work in (default: this one, or a resumed session's own)
          --max-turns N                rounds of tool calls a turn may take (default \(ORAgent.defaultMaxRounds))
          --input-format, --output-format text|stream-json
          --include-partial-messages   with stream-json output: the reply's text as it is written
        Tools run without asking; openrouter has no permission modes and no MCP. Claude Code's
        --permission-mode, --permission-prompt-tool, --mcp-config, --verbose and --dangerously-skip-permissions
        are taken, so that a host's command line works, and change nothing; a permission mode other than
        bypassPermissions, a prompt tool and an MCP config are each noted on stderr. Any other option is refused.
        Config: ~/.openrouter/config.json ({"apiKey": …, "model": …}); OPENROUTER_HOME moves it.
        """)
}

/// Says, on stderr, which of the options given will not do what they say.
func note(_ options: Options) {
    for note in options.notes { output.error("openrouter: " + note) }
}

func readSecret(prompt: String) -> String {
    output.text(prompt)
    var term = termios()
    tcgetattr(STDIN_FILENO, &term)
    var quiet = term
    quiet.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &quiet)
    defer { tcsetattr(STDIN_FILENO, TCSANOW, &term); output.text("\n") }
    return readLine() ?? ""
}

/// The config as it is on disk, for a command that will write it back; or
/// nil, having said why, when the file there cannot be read as a config
/// and so must not be replaced.
func configToChange() -> ORConfig? {
    do {
        return try ORConfig.read()
    } catch {
        output.error("\(ORConfig.file().path) is not a config openrouter can read (\(error.localizedDescription)); mend it or move it away first.")
        return nil
    }
}

func auth(_ subcommand: String?, _ rest: [String]) async -> Int32 {
    switch subcommand {
    case "login":
        var key = rest.first ?? ""
        if key.isEmpty { key = readSecret(prompt: "OpenRouter API key (https://openrouter.ai/keys): ") }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-or-") else { output.error("That does not look like an OpenRouter key (they start with sk-or-)."); return 1 }
        do {
            try await OpenRouterClient(apiKey: key).checkKey()
        } catch let refused as OpenRouterError where refused.status == 401 || refused.status == 403 {
            output.error("OpenRouter does not know that key.")
            return 1
        } catch {
            output.error("Could not check the key with OpenRouter: \(error.localizedDescription)")
            return 1
        }
        guard var config = configToChange() else { return 1 }
        config.apiKey = key
        do { try config.save() } catch { output.error("Could not save \(ORConfig.file().path): \(error.localizedDescription)"); return 1 }
        output.line("Saved to \(ORConfig.file().path)")
        return 0
    case "logout":
        guard var config = configToChange() else { return 1 }
        config.apiKey = nil
        do { try config.save() } catch { output.error("Could not save \(ORConfig.file().path): \(error.localizedDescription)"); return 1 }
        output.line("Key removed from \(ORConfig.file().path)")
        return 0
    case "status", nil:
        if let source = ORConfig.keySource() {
            output.line("Logged in: key from \(source)")
            output.line("Model: \(ORConfig.model(requested: nil))")
            return 0
        }
        output.line("Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY.")
        return 1
    default:
        output.error("openrouter auth status | login [KEY] | logout")
        return 2
    }
}

func models() async -> Int32 {
    // OpenRouter's model list is public: no login needed to see or keep it
    // (a host shows it before a key is set; running a model needs one).
    let cache = ORModelCache()
    do {
        // The list is kept on disk for hosts to read; asked for, it is
        // fetched afresh and kept again.
        var list = try await cache.refresh(client: OpenRouterClient())
        if options.flags.contains("refresh") { output.line("Kept \(list.count) models in \(cache.file.path)"); return 0 }
        if options.flags.contains("free") { list = list.filter(\.isFree) }
        if options.flags.contains("tools") { list = list.filter { $0.supportsTools } }
        if options.flags.contains("json") {
            let data = try JSONEncoder().encode(list)
            output.line(String(decoding: data, as: UTF8.self))
        } else {
            for model in list {
                let price = model.isFree ? "  free" : model.pricePerMillion.map { String(format: "  $%.2f/$%.2f per M", $0.input, $0.output) } ?? ""
                output.line(model.id + (model.contextLength.map { "  (\($0) ctx)" } ?? "") + (model.supportsTools ? "  tools" : "") + price)
            }
        }
        return 0
    } catch {
        output.error("\(error.localizedDescription)")
        return 1
    }
}

func sessions() -> Int32 {
    let list = ORSessionStore().list(cwd: options.values["cwd"])
    if options.flags.contains("json") {
        struct Row: Encodable { let id: String; let cwd: String; let model: String; let title: String; let updated: Double }
        let rows = list.map { Row(id: $0.id, cwd: $0.cwd, model: $0.model, title: $0.title, updated: $0.updated) }
        if let data = try? JSONEncoder().encode(rows) { output.line(String(decoding: data, as: UTF8.self)) }
        return 0
    }
    for session in list {
        let when = Date(timeIntervalSince1970: session.updated).formatted(date: .abbreviated, time: .shortened)
        output.line("\(session.id)  \(when)  \(session.cwd)  \(session.title)")
    }
    if list.isEmpty { output.line("No sessions yet.") }
    return 0
}

/// The headless mode: one prompt, or Claude Code's stream-json on stdin.
func headless() async -> Int32 {
    let streamIn = options.values["input-format"] == "stream-json"
    let streamOut = options.values["output-format"] == "stream-json"
    note(options)
    let conversation: Conversation
    do {
        conversation = try Conversation(resume: options.values["resume"], sessionID: options.values["session-id"], cwd: options.values["cwd"],
                                        model: options.values["model"], effort: options.values["effort"], maxRounds: options.maxTurns)
    } catch {
        let message = "Could not open the session: \(error.localizedDescription)"
        let id = options.values["resume"] ?? options.values["session-id"] ?? ""
        if streamOut { output.line(StreamJSON.result(.errorDuringExecution, text: message, sessionID: id)) } else { output.error(message) }
        return 1
    }
    if streamOut {
        output.line(StreamJSON.systemInit(sessionID: conversation.id, model: await conversation.model, cwd: conversation.cwd,
                                          tools: CodingTools.standard(cwd: conversation.cwd).map(\.name)))
    }
    // A host reads the model list from disk; keep it no older than a day.
    // The list is public, so this needs no key. It is fetched beside the
    // session, not before it, and a fetch that fails is left for the next
    // run: the list on disk stays as it was, and there is nobody to tell
    // (a host reads stderr for the session's failures, and this is not
    // one).
    let cache = ORModelCache()
    if cache.isStale { Task { _ = try? await cache.refresh(client: OpenRouterClient()) } }
    let runner = HeadlessRunner(conversation: conversation, streamOut: streamOut,
                                partialMessages: options.flags.contains("include-partial-messages"), output: output)
    if streamIn {
        do {
            for try await line in FileHandle.standardInput.bytes.lineFeedLines { await runner.take(line: line) }
        } catch {
            output.error("stdin: \(error.localizedDescription)")
        }
        await runner.drain()
        return 0
    }
    var prompt = options.positional.joined(separator: " ")
    if prompt.isEmpty, let data = try? FileHandle.standardInput.readToEnd() {
        prompt = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !prompt.isEmpty else { output.error("openrouter: nothing to say: give a prompt, or pipe one in."); return 2 }
    // One turn: its failure is the command's.
    return await runner.turn(prompt) ? 0 : 1
}

/// The terminal chat: type, watch the reply stream, see the tools run.
func chat(resume: String?) async -> Int32 {
    note(options)
    let conversation: Conversation
    do {
        conversation = try Conversation(resume: resume, sessionID: options.values["session-id"], cwd: options.values["cwd"],
                                        model: options.values["model"], effort: options.values["effort"], maxRounds: options.maxTurns)
    } catch {
        output.error("Could not open the session: \(error.localizedDescription)")
        return 1
    }
    guard await conversation.hasKey else {
        output.error("Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY.")
        return 1
    }
    output.line("openrouter \(version) · \(await conversation.model) · \(conversation.cwd)")
    output.line("session \(conversation.id) · /model <id> to switch · Ctrl-D to quit")
    while true {
        output.text("\n\u{203A} ")
        guard let entered = readLine() else { output.text("\n"); break }
        let text = entered.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { continue }
        if text.hasPrefix("/model ") {
            do {
                try await conversation.setModel(String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } catch {
                output.error(error.localizedDescription)
            }
            output.line("model: \(await conversation.model)")
            continue
        }
        if text == "/quit" || text == "/exit" { break }
        do {
            try await conversation.run(text) { event in
                switch event {
                case .delta(let piece, _): output.text(piece)
                case .toolCall(let name, let arguments, _):
                    let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
                    let summary = (object?["command"] ?? object?["path"]) as? String ?? ""
                    output.text("\n[\(name)] \(summary)\n")
                case .toolResult(_, let result, _, _):
                    let first = result.split(separator: "\n").prefix(3).joined(separator: "\n")
                    output.text("  \(first.replacingOccurrences(of: "\n", with: "\n  "))\n")
                case .started, .assistant, .usage: break
                }
            }
            output.text("\n")
        } catch {
            output.error("\n\(error.localizedDescription)")
        }
    }
    return 0
}

if options.flags.contains("version") || options.command == "version" { output.line(version); exit(0) }
if options.flags.contains("help") || options.command == "help" { usage(); exit(0) }

let status: Int32
switch options.command {
case "auth": status = await auth(options.positional.first, Array(options.positional.dropFirst()))
case "models": status = await models()
case "sessions": status = sessions()
case "resume":
    if let id = options.positional.first {
        status = await chat(resume: id)
    } else {
        output.error("openrouter: resume needs a session id (openrouter sessions lists them)")
        status = 2
    }
default: status = options.flags.contains("p") ? await headless() : await chat(resume: options.values["resume"])
}
exit(status)
