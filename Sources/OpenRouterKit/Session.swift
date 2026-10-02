// Sessions on disk, so a conversation can be resumed by id — by the CLI
// (`openrouter --resume <id>`) or by whatever drives it. One JSON file per
// session under ~/.openrouter/sessions/, rewritten as the conversation
// grows: the messages without the system prompt, the folder it ran in,
// the model, and when. Beside it, <id>.jsonl: the same messages as a log
// that is only ever appended to — a line per message, each with an id of
// its own, written as the message lands — which a host can follow as the
// conversation happens, as it follows Claude Code's and Codex's logs.

import Foundation

public struct ORSession: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var cwd: String
    public var model: String
    /// Seconds since 1970.
    public var created: Double
    public var updated: Double
    public var messages: [ORMessage]

    public init(id: String = ORSession.newID(), cwd: String, model: String, messages: [ORMessage] = [],
                created: Double = Date().timeIntervalSince1970, updated: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.cwd = cwd
        self.model = model
        self.messages = messages
        self.created = created
        self.updated = updated
    }

    /// A lowercase UUID, the shape Claude's and Codex's session ids have.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// The first thing the user said, shortened: what a list calls it.
    public var title: String {
        let first = messages.first { $0.role == .user }?.content ?? ""
        let line = first.split(separator: "\n").first.map(String.init) ?? first
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}

public enum ORSessionError: LocalizedError, Equatable {
    /// The id cannot name a session: it would not be a file in the
    /// sessions folder.
    case invalidID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let id): "\"\(id)\" is not a session id (letters, digits, \"-\", \"_\" and \".\", starting with a letter or digit)."
        }
    }
}

public struct ORSessionStore: Sendable {
    public let directory: URL

    public init(directory: URL = ORConfig.directory.appendingPathComponent("sessions", isDirectory: true)) {
        self.directory = directory
    }

    /// Whether an id can name a session. Ids become file names, and they
    /// come from outside (`--resume`, `--session-id`, a host): one with a
    /// "/" or a leading "." in it would name a file somewhere else.
    public static func isValid(id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.unicodeScalars.count <= 128 else { return false }
        let alphanumerics = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return alphanumerics.contains(first) && id.unicodeScalars.allSatisfy { alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    private func file(_ id: String, _ suffix: String) throws -> URL {
        guard Self.isValid(id: id) else { throw ORSessionError.invalidID(id) }
        return directory.appendingPathComponent(id + suffix)
    }

    /// The session's file. Throws for an id that cannot name one.
    public func url(for id: String) throws -> URL { try file(id, ".json") }

    public func load(id: String) throws -> ORSession {
        let data = try Data(contentsOf: url(for: id))
        return try JSONDecoder().decode(ORSession.self, from: data)
    }

    public func exists(id: String) -> Bool {
        guard let url = try? url(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func save(_ session: ORSession) throws {
        let url = try url(for: session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stamped = session
        stamped.updated = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stamped).write(to: url, options: .atomic)
    }

    public func remove(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
        try? FileManager.default.removeItem(at: logURL(for: id))
    }

    /// The session's log: a line per message, appended to only. Throws
    /// for an id that cannot name one.
    public func logURL(for id: String) throws -> URL { try file(id, ".jsonl") }

    /// How many messages the log holds.
    public func loggedCount(id: String) -> Int {
        guard let url = try? logURL(for: id), let data = try? Data(contentsOf: url) else { return 0 }
        return data.split(separator: 0x0A).filter { !$0.isEmpty }.count
    }

    /// Adds messages to the end of the log: each a line of its own,
    /// `{"id", "timestamp", "message"}`.
    public func appendLog(id: String, _ messages: [ORMessage]) throws {
        guard !messages.isEmpty else { return }
        let url = try logURL(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stamp = ISO8601DateFormatter().string(from: Date())
        var data = Data()
        for message in messages {
            let line = ORLogLine(id: UUID().uuidString.lowercased(), timestamp: stamp, message: message)
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Every session, newest first; only those run in `cwd` when given.
    public func list(cwd: String? = nil) -> [ORSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let wanted = cwd.map { ($0 as NSString).expandingTildeInPath }
        var sessions: [ORSession] = []
        for name in names where name.hasSuffix(".json") {
            guard let session = try? load(id: String(name.dropLast(5))) else { continue }
            if let wanted, (session.cwd as NSString).expandingTildeInPath != wanted { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.updated > $1.updated }
    }
}

/// One line of a session's log.
public struct ORLogLine: Codable, Sendable, Equatable {
    public var id: String
    public var timestamp: String
    public var message: ORMessage
}
