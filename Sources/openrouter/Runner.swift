// One conversation from the CLI's side: the agent with the coding tools
// in a folder, the session it is kept in on disk, and the turns run one
// at a time. Both the terminal chat and the headless mode drive this.

import Foundation
import OpenRouterKit
import Synchronization

/// A session's agent and its file, resumed or new. An actor: the session
/// is its state, written by the turn in flight and by whoever changes the
/// model.
actor Conversation {
    /// A turn was asked for with no key to run it.
    struct NoKey: LocalizedError {
        var errorDescription: String? {
            "No OpenRouter API key. Run `openrouter auth login <key>` on this computer (keys: https://openrouter.ai/keys), or set OPENROUTER_API_KEY."
        }
    }

    /// The turn ran, and what it added could not be written to disk.
    struct NotSaved: LocalizedError {
        let reason: String
        var errorDescription: String? { "The session could not be saved, so what this turn added will be lost when openrouter exits: \(reason)" }
    }

    private let store: ORSessionStore
    private let makeClient: @Sendable () -> OpenRouterClient
    private var session: ORSession
    nonisolated let id: String
    nonisolated let cwd: String
    private let agent: ORAgent
    private var client: OpenRouterClient
    /// How many of the conversation's messages the log already has.
    private var logged: Int
    /// The ids the agent gave this run's assistant messages, by their
    /// place in the history: the ids their lines in the log get.
    private var messageIDs: [Int: String] = [:]

    static let systemPrompt = """
        You are openrouter, a coding agent working in the folder %CWD% on the user's computer. \
        You have tools: bash (run a shell command), read_file, write_file, edit_file and list_directory. \
        Use them to look at and change the project rather than guessing, and run commands to verify your work. \
        Prefer small, precise edits. Answer concisely in GitHub-flavored Markdown; when a task is done, \
        say what changed.
        """

    /// - Parameters:
    ///   - resume: a session id to carry on (its file must exist).
    ///   - sessionID: the id a new session should have (a host that names
    ///     them); refused when a session already has it.
    ///   - cwd: the folder to work in, when one is chosen (`--cwd`). With
    ///     none, a new session works in the current folder and a resumed
    ///     one in the folder it was working in.
    ///   - maxRounds: how many rounds of tool calls a turn may take
    ///     (`--max-turns`); the agent's own limit when nil.
    ///   - store: where sessions are kept.
    ///   - makeClient: the client, made afresh for each turn with the key
    ///     as it is then.
    init(resume: String?, sessionID: String?, cwd chosen: String?, model requested: String?, effort: String?, maxRounds: Int?,
         store: ORSessionStore = ORSessionStore(), makeClient: @escaping @Sendable () -> OpenRouterClient = { OpenRouterClient() }) throws {
        // The folder as an absolute path: it is kept in the session, read
        // by hosts, and has to mean the same from anywhere.
        let folder = chosen.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        var session: ORSession
        if let resume {
            session = try store.load(id: resume)
            if let requested, !requested.isEmpty { session.model = requested }
            if let folder { session.cwd = folder }
        } else {
            let id = sessionID ?? ORSession.newID()
            // Checked now: an id that cannot name a session file would
            // fail at the first save, and one a session already has would
            // write a new, empty session over it.
            guard !(try store.exists(id: id)) else { throw ORSessionError.alreadyExists(id) }
            session = ORSession(id: id, cwd: folder ?? FileManager.default.currentDirectoryPath, model: ORConfig.model(requested: requested))
        }
        let client = makeClient()
        self.store = store
        self.makeClient = makeClient
        self.session = session
        self.client = client
        id = session.id
        cwd = session.cwd
        agent = ORAgent(client: client, model: session.model, tools: CodingTools.standard(cwd: session.cwd),
                        systemPrompt: Self.systemPrompt.replacingOccurrences(of: "%CWD%", with: session.cwd),
                        history: session.messages, reasoningEffort: Self.effort(effort), maxRounds: maxRounds ?? ORAgent.defaultMaxRounds)
        // The log holds a line for each message it has been given. One
        // with more lines than the session has messages (a save that
        // failed after its append, in an earlier build) is taken as
        // holding them all: what this run adds is appended after it.
        logged = min(store.loggedCount(id: session.id), session.messages.count)
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

    /// The model from the next turn on, kept in the session file.
    func setModel(_ model: String) async throws {
        session.model = model
        await agent.setModel(model)
        await save()
        if let unsaved { throw NotSaved(reason: unsaved) }
    }

    /// The key is read afresh for each turn, so a key set after launch
    /// (in the config file) is picked up without a restart.
    private func refreshKey() async {
        let fresh = makeClient()
        guard fresh.apiKey != client.apiKey else { return }
        client = fresh
        await agent.setClient(fresh)
    }

    /// Runs one user turn, handing each event on, and keeps the session
    /// file current as messages land: the user's message at once, so a
    /// host following the log shows it as it is sent. Throws what the
    /// turn threw (`CancellationError` when it was interrupted), and
    /// `NotSaved` when the turn ran and the session could not be written.
    func run(_ text: String, sink: @Sendable (ORAgentEvent) async -> Void) async throws {
        await refreshKey()
        guard client.hasKey else { throw NoKey() }
        let turn: Result<Void, any Error>
        do {
            try await agent.send(text) { event in
                await sink(event)
                switch event {
                case .assistant(_, let id): await self.save(naming: id)
                case .started, .toolResult: await self.save()
                case .delta, .toolCall, .message, .usage: break
                }
            }
            turn = .success(())
        } catch {
            turn = .failure(error)
        }
        // Once more, whatever happened: what a save during the turn could
        // not write is tried again, and a turn that threw is on disk as
        // far as it got.
        await save()
        try turn.get()
        if let unsaved { throw NotSaved(reason: unsaved) }
    }

    /// Why the last save failed, when it did.
    private var unsaved: String?

    /// Writes the session file and adds to the log what it does not have
    /// yet. A failure is kept in `unsaved` for the turn to report: an
    /// event's handler cannot throw, and the turn should not stop for it.
    /// - Parameter latest: the id of the assistant message that has just
    ///   landed, the last in the history.
    private func save(naming latest: String? = nil) async {
        let history = await agent.history
        if let latest { messageIDs[history.count - 1] = latest }
        session.messages = history
        do {
            try store.save(session)
            // A session from before the log gets its whole history the
            // first time. An assistant message's line gets the message's
            // id, the one it streamed under.
            if history.count > logged {
                let ids = Dictionary(uniqueKeysWithValues: (logged..<history.count).compactMap { place in
                    messageIDs[place].map { (place - logged, $0) }
                })
                try store.appendLog(id: session.id, Array(history[logged...]), ids: ids)
                logged = history.count
            }
            unsaved = nil
        } catch {
            unsaved = error.localizedDescription
        }
    }
}

/// Where the CLI writes: stdout, a line or a piece of text at a time, and
/// stderr. Each write is whole under its lock, so a turn's events and the
/// answers to control requests never interleave.
final class Output: Sendable {
    static let standard = Output(out: .standardOutput, err: .standardError)

    private let out: Mutex<FileHandle>
    private let err: Mutex<FileHandle>

    init(out: FileHandle, err: FileHandle) {
        self.out = Mutex(out)
        self.err = Mutex(err)
    }

    func line(_ text: String) { Self.write(text + "\n", to: out) }

    func text(_ text: String) { Self.write(text, to: out) }

    func error(_ text: String) { Self.write(text + "\n", to: err) }

    private static func write(_ text: String, to handle: borrowing Mutex<FileHandle>) {
        // A write that fails has nowhere to be reported: whoever was
        // reading has gone.
        handle.withLock { try? $0.write(contentsOf: Data(text.utf8)) }
    }
}

/// A turn's events as stream-json lines: the message boundaries, and the
/// usage that goes on the finished message. A message's lines carry the
/// id the agent gave it. The reply's text as it is written (the
/// `stream_event` lines) is printed only when asked for, as Claude Code
/// prints it only with `--include-partial-messages`; the finished
/// messages always are.
actor StreamJSONTurn {
    private let model: String
    private let partialMessages: Bool
    private let output: Output
    /// The message whose `message_start` has been written and whose
    /// `assistant` line has not.
    private var open: String?
    private var usage: (prompt: Int, completion: Int)?
    /// The text of the last assistant message: what the result carries.
    private(set) var lastText = ""

    init(model: String, partialMessages: Bool, output: Output) {
        self.model = model
        self.partialMessages = partialMessages
        self.output = output
    }

    private func start(_ id: String) {
        guard partialMessages, open != id else { return }
        open = id
        output.line(StreamJSON.messageStart(id: id))
    }

    func handle(_ event: ORAgentEvent) {
        switch event {
        case .delta(let text, let id):
            guard partialMessages else { break }
            start(id)
            output.line(StreamJSON.textDelta(text))
        case .usage(let prompt, let completion):
            usage = (prompt, completion)
        case .assistant(let message, let id):
            start(id)
            output.line(StreamJSON.assistant(id: id, model: model, message: message, usage: usage))
            if let text = message.content, !text.isEmpty { lastText = text }
            open = nil
            usage = nil
        case .toolResult(_, let result, let id, let isError):
            output.line(StreamJSON.toolResult(callID: id, output: result, isError: isError))
        case .started, .message, .toolCall:
            break
        }
    }
}

/// The headless loop: stdin lines in, stream-json (or text) out. Turns
/// run one at a time; a message arriving mid-turn waits its turn; an
/// interrupt cancels the turn in flight, which ends with an error result
/// of its own.
actor HeadlessRunner {
    private let conversation: Conversation
    private let streamOut: Bool
    private let partialMessages: Bool
    private let output: Output
    private var queue: [String] = []
    private var current: Task<Void, Never>?

    /// - Parameters:
    ///   - streamOut: stream-json on stdout, rather than the reply's text.
    ///   - partialMessages: with stream-json, the reply's text as it is
    ///     written too (`--include-partial-messages`).
    init(conversation: Conversation, streamOut: Bool, partialMessages: Bool, output: Output) {
        self.conversation = conversation
        self.streamOut = streamOut
        self.partialMessages = partialMessages
        self.output = output
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
        current = Task {
            await turn(text)
            current = nil
            pump()
        }
    }

    /// Waits for everything queued to run.
    func drain() async {
        while let task = current {
            await task.value
        }
    }

    /// Runs one turn and reports how it ended: a result line (stream-json)
    /// or the reply's text, with a failure on stderr. Whether it succeeded.
    @discardableResult
    func turn(_ text: String) async -> Bool {
        let id = conversation.id
        let lines = StreamJSONTurn(model: await conversation.model, partialMessages: partialMessages, output: output)
        do {
            try await conversation.run(text) { [streamOut, output] event in
                if streamOut {
                    await lines.handle(event)
                } else if case .delta(let piece, _) = event {
                    output.text(piece)
                }
            }
            if streamOut { output.line(StreamJSON.result(.success, text: await lines.lastText, sessionID: id)) } else { output.text("\n") }
            return true
        } catch {
            let message = error is CancellationError ? "Interrupted" : (error as? LocalizedError)?.errorDescription ?? "\(error)"
            // Out of rounds is the one failure Claude Code names apart.
            let kind: StreamJSON.ResultKind = if case ORAgentError.tooManyRounds = error { .errorMaxTurns } else { .errorDuringExecution }
            if streamOut { output.line(StreamJSON.result(kind, text: message, sessionID: id)) } else { output.error(message) }
            return false
        }
    }
}
