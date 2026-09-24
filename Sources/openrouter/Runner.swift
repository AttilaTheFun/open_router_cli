// One conversation from the CLI's side: the agent with the coding tools
// in a folder, the session it is kept in on disk, and the turns run one
// at a time. Both the terminal chat and the headless mode drive this.

import Foundation
import OpenRouterKit

/// A session's agent and its file, resumed or new.
final class Conversation: @unchecked Sendable {
    let store = ORSessionStore()
    private(set) var session: ORSession
    let cwd: String
    private(set) var agent: ORAgent
    private var client: OpenRouterClient

    static let systemPrompt = """
        You are openrouter, a coding agent working in the folder %CWD% on the user's computer. \
        You have tools: bash (run a shell command), read_file, write_file, edit_file and list_directory. \
        Use them to look at and change the project rather than guessing, and run commands to verify your work. \
        Prefer small, precise edits. Answer concisely in GitHub-flavored Markdown; when a task is done, \
        say what changed.
        """

    /// - Parameters:
    ///   - resume: a session id to carry on (its file must exist).
    ///   - sessionID: the id a new session should have (a host that names them).
    init(resume: String?, sessionID: String?, cwd: String, model requested: String?, effort: String?) throws {
        let root = (cwd as NSString).expandingTildeInPath
        self.cwd = root
        if let resume, !resume.isEmpty {
            var kept = try store.load(id: resume)
            if let requested, !requested.isEmpty { kept.model = requested }
            session = kept
        } else {
            session = ORSession(id: sessionID ?? ORSession.newID(), cwd: root, model: ORConfig.model(requested: requested))
        }
        client = OpenRouterClient()
        agent = ORAgent(client: client, model: session.model, tools: CodingTools.standard(cwd: root),
                        systemPrompt: Self.systemPrompt.replacingOccurrences(of: "%CWD%", with: root),
                        reasoningEffort: Self.effort(effort))
        agent.load(session.messages)
    }

    var model: String { session.model }
    var hasKey: Bool { client.hasKey }

    /// "low"/"medium"/"high" as OpenRouter takes them; the levels above
    /// high (Claude's xhigh, max) read as high; nothing for anything else.
    static func effort(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "low", "medium", "high": return value?.lowercased()
        case "xhigh", "max": return "high"
        default: return nil
        }
    }

    func setModel(_ model: String) {
        session.model = model
        agent.model = model
    }

    /// The key is read afresh for each turn, so a key set after launch
    /// (in the config file) is picked up without a restart.
    func refreshKey() {
        let fresh = OpenRouterClient()
        guard fresh.apiKey != client.apiKey else { return }
        client = fresh
        let rebuilt = ORAgent(client: fresh, model: agent.model, tools: CodingTools.standard(cwd: cwd),
                              systemPrompt: Self.systemPrompt.replacingOccurrences(of: "%CWD%", with: cwd),
                              reasoningEffort: agent.reasoningEffort)
        rebuilt.load(agent.history)
        agent = rebuilt
    }

    /// Runs one user turn, handing each event on, and keeps the session
    /// file current as messages land. Throws what the API threw; the
    /// conversation so far is saved either way.
    func run(_ text: String, sink: @escaping @Sendable (ORAgentEvent) -> Void) async throws {
        refreshKey()
        defer { save() }
        for try await event in agent.send(text) {
            sink(event)
            if case .assistant = event { save() }
            if case .toolResult = event { save() }
        }
    }

    func save() {
        session.messages = agent.history
        try? store.save(session)
    }
}

/// Where lines go: stdout, one at a time, flushed. Every turn's events and
/// the terminal's text pass through here so they never interleave.
enum Output {
    private static let lock = NSLock()

    static func line(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func text(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// A turn's events as stream-json lines: the ids, the message boundaries,
/// the usage that goes on the finished message.
final class StreamJSONTurn: @unchecked Sendable {
    private let model: String
    private var counter = 0
    private var messageID = ""
    private var started = false
    private var usage: (prompt: Int, completion: Int)?
    private(set) var lastText = ""
    private let lock = NSLock()

    init(model: String) { self.model = model }

    private func nextID() -> String {
        counter += 1
        return "msg_or_" + String(UUID().uuidString.prefix(8)).lowercased() + "_\(counter)"
    }

    func handle(_ event: ORAgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .delta(let text):
            if !started { messageID = nextID(); started = true; Output.line(StreamJSON.messageStart(id: messageID)) }
            Output.line(StreamJSON.textDelta(text))
        case .usage(let prompt, let completion):
            usage = (prompt, completion)
        case .assistant(let message):
            if !started { messageID = nextID(); started = true; Output.line(StreamJSON.messageStart(id: messageID)) }
            Output.line(StreamJSON.assistant(id: messageID, model: model, message: message, usage: usage))
            if let text = message.content, !text.isEmpty { lastText = text }
            started = false
            usage = nil
        case .toolResult(_, let output, let id):
            Output.line(StreamJSON.toolResult(callID: id, output: output, isError: output.hasPrefix("Error:")))
        case .message, .toolCall, .done:
            break
        }
    }
}

/// The headless loop: stdin lines in, stream-json (or text) out. Turns
/// run one at a time; a message arriving mid-turn waits its turn; an
/// interrupt cancels the turn in flight.
actor HeadlessRunner {
    private let conversation: Conversation
    private let streamOut: Bool
    private var queue: [String] = []
    private var current: Task<Void, Never>?

    init(conversation: Conversation, streamOut: Bool) {
        self.conversation = conversation
        self.streamOut = streamOut
    }

    func enqueue(_ text: String) {
        queue.append(text)
        pump()
    }

    func interrupt() {
        current?.cancel()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        current = Task { [conversation, streamOut] in
            await Self.turn(text, conversation: conversation, streamOut: streamOut)
            self.finished()
        }
    }

    private func finished() {
        current = nil
        pump()
    }

    /// Waits for everything queued to run.
    func drain() async {
        while let task = current {
            await task.value
        }
    }

    static func turn(_ text: String, conversation: Conversation, streamOut: Bool) async {
        let id = conversation.session.id
        guard conversation.hasKey || ORConfig.resolvedKey() != nil else {
            let message = "No OpenRouter API key. Run `openrouter auth login <key>` on this computer (keys: https://openrouter.ai/keys), or set OPENROUTER_API_KEY."
            if streamOut { Output.line(StreamJSON.result(isError: true, text: message, sessionID: id)) } else { Output.error(message) }
            return
        }
        let turn = StreamJSONTurn(model: conversation.model)
        do {
            try await conversation.run(text) { event in
                if streamOut {
                    turn.handle(event)
                } else if case .delta(let piece) = event {
                    Output.text(piece)
                }
            }
            if streamOut { Output.line(StreamJSON.result(isError: false, text: turn.lastText, sessionID: id)) } else { Output.text("\n") }
        } catch is CancellationError {
            if streamOut { Output.line(StreamJSON.result(isError: true, text: "Interrupted", sessionID: id)) }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if streamOut { Output.line(StreamJSON.result(isError: true, text: message, sessionID: id)) } else { Output.error(message) }
        }
    }
}
