// The coding tools: what makes the model an agent in a folder rather than
// a chat. A shell, and files read, written, edited and listed, all
// relative to the working directory. The shapes are the ones the popular
// agents use (`command`, `path`, `old_string`/`new_string`), so a consumer
// that summarises a call by its input reads them the same way.

import Foundation

public enum CodingTools {
    /// The standard set, rooted at `cwd`.
    public static func standard(cwd: String) -> [any ORTool] {
        let root = (cwd as NSString).expandingTildeInPath
        return [BashTool(cwd: root), ReadFileTool(cwd: root), WriteFileTool(cwd: root), EditFileTool(cwd: root), ListDirectoryTool(cwd: root)]
    }

    /// A path from the model, resolved under the working directory.
    static func resolve(_ path: String, in cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return (cwd as NSString).appendingPathComponent(expanded)
    }

    static func arguments(_ json: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    }

    /// Output the model sees is capped: a build log is not a conversation.
    static func capped(_ text: String, limit: Int = 30_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters truncated)"
    }
}

struct ToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public struct BashTool: ORTool {
    public let name = "bash"
    public let toolDescription = "Run a shell command in the working directory and return its output (stdout and stderr) and exit status. Use for builds, tests, git, searches, and anything else a terminal does."
    public let parametersJSON = """
        {"type":"object","properties":{"command":{"type":"string","description":"The command to run with zsh -c"},"timeout":{"type":"integer","description":"Seconds before the command is killed (default 120)"}},"required":["command"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let command = args["command"] as? String, !command.isEmpty else { throw ToolFailure(message: "bash needs a command") }
        // Seconds; a model that sends milliseconds gets the cap.
        let timeout = min(600, max(1, (args["timeout"] as? Int) ?? 120))
        let cwd = cwd
        return try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            // Drained on its own thread: a command that fills the pipe
            // would otherwise block before it exits.
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box()
            let reader = Thread { box.data = out.fileHandleForReading.readDataToEndOfFile() }
            do { try p.run() } catch { throw ToolFailure(message: "could not run: \(error.localizedDescription)") }
            reader.start()
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while p.isRunning && Date() < deadline { usleep(20_000) }
            var timedOut = false
            if p.isRunning { timedOut = true; p.terminate(); usleep(200_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
            p.waitUntilExit()
            while !reader.isFinished { usleep(10_000) }
            var text = String(decoding: box.data, as: UTF8.self)
            if timedOut { text += "\n(killed after \(timeout)s)" }
            text += "\n[exit \(p.terminationStatus)]"
            return CodingTools.capped(text)
        }.value
    }
}

public struct ReadFileTool: ORTool {
    public let name = "read_file"
    public let toolDescription = "Read a text file. Returns its lines, numbered, from `offset` (1-based) for `limit` lines (default the first 400)."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let path = args["path"] as? String else { throw ToolFailure(message: "read_file needs a path") }
        let full = CodingTools.resolve(path, in: cwd)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { throw ToolFailure(message: "cannot read \(full)") }
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, (args["offset"] as? Int) ?? 1)
        let limit = max(1, (args["limit"] as? Int) ?? 400)
        guard offset <= lines.count else { return "(file has \(lines.count) lines)" }
        let slice = lines[(offset - 1)..<min(lines.count, offset - 1 + limit)]
        var out = ""
        for (i, line) in slice.enumerated() { out += "\(offset + i)\t\(line)\n" }
        if offset - 1 + limit < lines.count { out += "… (\(lines.count - (offset - 1 + limit)) more lines)\n" }
        return CodingTools.capped(out)
    }
}

public struct WriteFileTool: ORTool {
    public let name = "write_file"
    public let toolDescription = "Write a whole text file, creating it and its folders as needed. Overwrites what was there."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let path = args["path"] as? String, let content = args["content"] as? String else { throw ToolFailure(message: "write_file needs path and content") }
        let full = CodingTools.resolve(path, in: cwd)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: full, atomically: true, encoding: .utf8)
        return "wrote \(content.utf8.count) bytes to \(full)"
    }
}

public struct EditFileTool: ORTool {
    public let name = "edit_file"
    public let toolDescription = "Replace one exact occurrence of `old_string` in a file with `new_string`. Fails if the old text is missing or not unique; include enough context to make it unique."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let path = args["path"] as? String, let old = args["old_string"] as? String, let new = args["new_string"] as? String else {
            throw ToolFailure(message: "edit_file needs path, old_string and new_string")
        }
        let full = CodingTools.resolve(path, in: cwd)
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { throw ToolFailure(message: "cannot read \(full)") }
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else { throw ToolFailure(message: count == 0 ? "old_string not found in \(full)" : "old_string occurs \(count) times in \(full); make it unique") }
        let edited = text.replacingOccurrences(of: old, with: new)
        try edited.write(toFile: full, atomically: true, encoding: .utf8)
        return "edited \(full)"
    }
}

public struct ListDirectoryTool: ORTool {
    public let name = "list_directory"
    public let toolDescription = "List a folder's entries (folders end with /). Defaults to the working directory."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"}}}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        let full = CodingTools.resolve((args["path"] as? String) ?? ".", in: cwd)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: full) else { throw ToolFailure(message: "cannot list \(full)") }
        var lines: [String] = []
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: (full as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            lines.append(isDirectory.boolValue ? name + "/" : name)
        }
        return CodingTools.capped(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }
}
