// The coding tools: what makes the model an agent in a folder rather than
// a chat. A shell, and files read, written, edited and listed. The shapes
// are the ones the popular agents use (`command`, `path`,
// `old_string`/`new_string`), so a consumer that summarises a call by its
// input reads them the same way.
//
// The file tools reach only inside the working directory: a path that
// leads out of it (`..`, an absolute path, `~`, a symbolic link) is
// refused. The shell is not confined — it runs whatever the model writes,
// as the user — so with bash in the set the folder is where the agent
// works, not a wall around it; a host that wants the wall leaves bash out.

import Foundation

public enum CodingTools {
    /// The standard set, rooted at `cwd`.
    public static func standard(cwd: String) -> [any ORTool] {
        let root = (cwd as NSString).expandingTildeInPath
        return [BashTool(cwd: root), ReadFileTool(cwd: root), WriteFileTool(cwd: root), EditFileTool(cwd: root), ListDirectoryTool(cwd: root)]
    }

    /// A path from the model as the file it names, which must be inside
    /// the working directory: relative paths start there, and where the
    /// path ends up is judged with `..` and symbolic links followed, so
    /// neither leads out. The path returned is that end, and is what the
    /// tool then opens.
    static func resolve(_ path: String, in cwd: String) throws -> String {
        // A NUL ends a path for the system and not for Swift: what is
        // checked here and what is then opened could differ.
        guard !path.utf8.contains(0) else { throw ToolFailure(message: "a path cannot have a NUL character in it") }
        let expanded = (path as NSString).expandingTildeInPath
        let root = try canonical(components(URL(fileURLWithPath: cwd).path))
        let isAbsolute = expanded.utf8.first == UInt8(ascii: "/")
        let target = try canonical(isAbsolute ? components(expanded) : root + components(expanded))
        guard target.starts(with: root) else {
            throw ToolFailure(message: "\(path) is outside the working directory (\(cwd)); the file tools only reach inside it")
        }
        return "/" + target.joined(separator: "/")
    }

    /// A path's names, split where the system splits it: at each "/"
    /// byte. (Split as Swift characters, a "/" followed by a combining
    /// mark is one character and no separator at all, and a name could
    /// hide a step through a link.)
    static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The names of an absolute path with `.` and `..` taken out and every
    /// symbolic link followed, whether or not anything exists at its end
    /// yet (a file about to be written has no path to ask the system
    /// about).
    static func canonical(_ names: [String]) throws -> [String] {
        var pending = Array(names.reversed())
        var resolved: [String] = []
        var links = 0
        while let name = pending.popLast() {
            if name == "." { continue }
            if name == ".." { _ = resolved.popLast(); continue }
            let here = "/" + (resolved + [name]).joined(separator: "/")
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: here) else {
                resolved.append(name)
                continue
            }
            // A link: what it points to takes its place, from the root if
            // it is absolute, and is walked in turn.
            links += 1
            guard links <= 64 else { throw ToolFailure(message: "too many symbolic links in /\(names.joined(separator: "/"))") }
            if destination.utf8.first == UInt8(ascii: "/") { resolved = [] }
            pending.append(contentsOf: components(destination).reversed())
        }
        return resolved
    }

    /// A text file's contents, or a failure that says why not (missing,
    /// not UTF-8, not permitted): the model can act on the reason.
    static func read(_ full: String) throws -> String {
        do {
            return try String(contentsOfFile: full, encoding: .utf8)
        } catch {
            throw ToolFailure(message: "cannot read \(full): \(error.localizedDescription)")
        }
    }

    static func arguments(_ json: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    }

    /// How much of a tool's output the model sees, in characters (bytes,
    /// for a command's): a build log is not a conversation.
    static let outputLimit = 30_000

    static func capped(_ text: String) -> String {
        guard text.count > outputLimit else { return text }
        return String(text.prefix(outputLimit)) + "\n… (\(text.count - outputLimit) more characters truncated)"
    }
}

struct ToolFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

public struct BashTool: ORTool {
    public let name = "bash"
    public let toolDescription = "Run a shell command in the working directory and return its output (stdout and stderr) and exit status. Use for builds, tests, git, searches, and anything else a terminal does. Output is read until the command exits: a job left running in the background must redirect its own output."
    public let parametersJSON = """
        {"type":"object","properties":{"command":{"type":"string","description":"The command to run with zsh -lc"},"timeout":{"type":"integer","description":"Seconds before the command is killed (default 120, at most 600)"}},"required":["command"]}
        """
    let cwd: String
    let environment: [String: String]?

    /// - Parameter environment: the environment the command runs in;
    ///   this process's own when nil.
    public init(cwd: String, environment: [String: String]? = nil) {
        self.cwd = cwd
        self.environment = environment
    }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let command = args["command"] as? String, !command.isEmpty else { throw ToolFailure(message: "bash needs a command") }
        // Seconds; a model that sends milliseconds gets the cap.
        let timeout = min(600, max(1, (args["timeout"] as? Int) ?? 120))
        // Output past the limit is counted and dropped as it arrives.
        let outcome = try await Shell.run(command, cwd: cwd, environment: environment, timeout: .seconds(timeout), keep: CodingTools.outputLimit)
        var text = String(decoding: outcome.output, as: UTF8.self)
        if outcome.dropped > 0 { text += "\n… (\(outcome.dropped) more bytes truncated)" }
        switch outcome.stopped {
        case .deadline: text += "\n(killed after \(timeout)s)"
        case .cancelled: text += "\n(interrupted)"
        case nil: break
        }
        text += outcome.signalled ? "\n[signal \(outcome.status)]" : "\n[exit \(outcome.status)]"
        return text
    }
}

public struct ReadFileTool: ORTool {
    public let name = "read_file"
    public let toolDescription = "Read a text file in the working directory. Returns its lines, numbered, from `offset` (1-based) for `limit` lines (default the first 400)."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["path"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let path = args["path"] as? String else { throw ToolFailure(message: "read_file needs a path") }
        let full = try CodingTools.resolve(path, in: cwd)
        var lines = try CodingTools.read(full).components(separatedBy: "\n")
        // The newline that ends the last line begins no line of its own.
        if lines.last == "" { lines.removeLast() }
        let offset = max(1, (args["offset"] as? Int) ?? 1)
        let limit = max(1, (args["limit"] as? Int) ?? 400)
        guard offset <= lines.count else { return "(file has \(lines.count) lines)" }
        // The model's numbers are any integers at all: the end is found
        // by comparing with what is left, never by adding to them.
        let start = offset - 1
        let end = limit < lines.count - start ? start + limit : lines.count
        var out = ""
        for (i, line) in lines[start..<end].enumerated() { out += "\(offset + i)\t\(line)\n" }
        if end < lines.count { out += "… (\(lines.count - end) more lines)\n" }
        return CodingTools.capped(out)
    }
}

public struct WriteFileTool: ORTool {
    public let name = "write_file"
    public let toolDescription = "Write a whole text file in the working directory, creating it and its folders as needed. Overwrites what was there."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        guard let path = args["path"] as? String, let content = args["content"] as? String else { throw ToolFailure(message: "write_file needs path and content") }
        let full = try CodingTools.resolve(path, in: cwd)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: full, atomically: true, encoding: .utf8)
        return "wrote \(content.utf8.count) bytes to \(full)"
    }
}

public struct EditFileTool: ORTool {
    public let name = "edit_file"
    public let toolDescription = "Replace one exact occurrence of `old_string` in a file in the working directory with `new_string`. Fails if the old text is missing or not unique; include enough context to make it unique."
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
        guard !old.isEmpty else { throw ToolFailure(message: "old_string is empty; give the text to replace") }
        let full = try CodingTools.resolve(path, in: cwd)
        let text = try CodingTools.read(full)
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else { throw ToolFailure(message: count == 0 ? "old_string not found in \(full)" : "old_string occurs \(count) times in \(full); make it unique") }
        let edited = text.replacingOccurrences(of: old, with: new)
        try edited.write(toFile: full, atomically: true, encoding: .utf8)
        return "edited \(full)"
    }
}

public struct ListDirectoryTool: ORTool {
    public let name = "list_directory"
    public let toolDescription = "List a folder's entries (folders end with /): the working directory, or a folder inside it."
    public let parametersJSON = """
        {"type":"object","properties":{"path":{"type":"string"}}}
        """
    let cwd: String

    public init(cwd: String) { self.cwd = cwd }

    public func call(arguments: String) async throws -> String {
        let args = CodingTools.arguments(arguments)
        let full = try CodingTools.resolve((args["path"] as? String) ?? ".", in: cwd)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: full)
        } catch {
            throw ToolFailure(message: "cannot list \(full): \(error.localizedDescription)")
        }
        var lines: [String] = []
        for name in names.sorted() {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: (full as NSString).appendingPathComponent(name), isDirectory: &isDirectory)
            lines.append(isDirectory.boolValue ? name + "/" : name)
        }
        return CodingTools.capped(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }
}
