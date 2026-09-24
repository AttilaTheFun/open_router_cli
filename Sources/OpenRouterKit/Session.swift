// Sessions on disk, so a conversation can be resumed by id — by the CLI
// (`openrouter --resume <id>`) or by whatever drives it. One JSON file per
// session under ~/.openrouter/sessions/, rewritten as the conversation
// grows: the messages without the system prompt, the folder it ran in,
// the model, and when.

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

public struct ORSessionStore: Sendable {
    public let directory: URL

    public init(directory: URL = ORConfig.directory.appendingPathComponent("sessions", isDirectory: true)) {
        self.directory = directory
    }

    public func url(for id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    public func load(id: String) throws -> ORSession {
        let data = try Data(contentsOf: url(for: id))
        return try JSONDecoder().decode(ORSession.self, from: data)
    }

    public func exists(id: String) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }

    public func save(_ session: ORSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stamped = session
        stamped.updated = Date().timeIntervalSince1970
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stamped).write(to: url(for: session.id), options: .atomic)
    }

    public func remove(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
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
