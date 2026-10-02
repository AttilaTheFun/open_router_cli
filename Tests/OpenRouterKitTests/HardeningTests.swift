// What comes from outside is not trusted to be a path inside the folder,
// a file name, or a small number: the file tools stay in the working
// directory, a session id names a file in the sessions folder or nothing,
// and the read tool's arithmetic holds for any integers.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

private func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// A working directory with a file in it, a folder beside it that is not
/// the tools' to touch, and links from the one into the other.
private struct Folders {
    let root: URL
    let outside: URL

    init() throws {
        let base = try scratch()
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        try "inside".write(to: root.appendingPathComponent("sub/in.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        // A folder link out, a file link out, a link out to nothing yet, and a link that stays in.
        try files.createSymbolicLink(atPath: root.appendingPathComponent("out").path, withDestinationPath: "../outside")
        try files.createSymbolicLink(atPath: root.appendingPathComponent("secret-link").path, withDestinationPath: outside.appendingPathComponent("secret.txt").path)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: outside.appendingPathComponent("new.txt").path)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "sub")
    }

    /// The names in the outside folder: what must not change.
    func outsideNames() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() }
}

// MARK: Paths

@Test func pathsInsideTheWorkingDirectoryResolve() throws {
    let folders = try Folders()
    let root = "/" + (try CodingTools.canonical(CodingTools.components(folders.root.path))).joined(separator: "/")
    #expect(try CodingTools.resolve("sub/in.txt", in: folders.root.path) == root + "/sub/in.txt")
    #expect(try CodingTools.resolve(".", in: folders.root.path) == root)
    #expect(try CodingTools.resolve("sub/../sub/./in.txt", in: folders.root.path) == root + "/sub/in.txt")
    // Not there yet, in a folder not there yet: still inside.
    #expect(try CodingTools.resolve("new/deep/file.txt", in: folders.root.path) == root + "/new/deep/file.txt")
    // An absolute path that is inside, and a link that stays inside.
    #expect(try CodingTools.resolve(folders.root.path + "/sub/in.txt", in: folders.root.path) == root + "/sub/in.txt")
    #expect(try CodingTools.resolve("alias/in.txt", in: folders.root.path) == root + "/sub/in.txt")
}

@Test(arguments: [
    "../outside/secret.txt",          // up and out
    "sub/../../outside/secret.txt",   // the same, from further in
    "..",                             // the folder above
    "/etc/hosts",                     // absolute
    "~/.zshrc",                       // the home folder
    "out/secret.txt",                 // through a folder link
    "out/new.txt",                    // through a folder link, to a file not there yet
    "secret-link",                    // a file link
    "dangling",                       // a link to a file not there yet
    "alias/../../outside/secret.txt", // a link in, then up and out
])
func pathsThatLeadOutAreRefused(path: String) throws {
    let folders = try Folders()
    #expect(throws: ToolFailure.self) { try CodingTools.resolve(path, in: folders.root.path) }
}

@Test func aFolderWithTheSameStartIsNotInside() throws {
    let base = try scratch()
    try FileManager.default.createDirectory(at: base.appendingPathComponent("root-other"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: base.appendingPathComponent("root"), withIntermediateDirectories: true)
    #expect(throws: ToolFailure.self) { try CodingTools.resolve("../root-other/x", in: base.appendingPathComponent("root").path) }
}

@Test func aLoopOfLinksIsRefused() throws {
    let root = try scratch()
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("a").path, withDestinationPath: "b")
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("b").path, withDestinationPath: "a")
    let failure = #expect(throws: ToolFailure.self) { try CodingTools.resolve("a/file", in: root.path) }
    #expect(failure?.message.hasPrefix("too many symbolic links in /") == true)
    #expect(failure?.message.hasSuffix("/a/file") == true)
}

/// The refusal says what was refused and where the tools do reach, for
/// the model to act on.
@Test func aRefusalSaysWhy() throws {
    let folders = try Folders()
    #expect(throws: ToolFailure(message: "../outside/secret.txt is outside the working directory (\(folders.root.path)); the file tools only reach inside it")) {
        try CodingTools.resolve("../outside/secret.txt", in: folders.root.path)
    }
}

@Test func theFileToolsDoNotReachOutside() async throws {
    let folders = try Folders()
    let before = try folders.outsideNames()
    let tools = CodingTools.standard(cwd: folders.root.path)
    func tool(_ name: String) throws -> any ORTool { try #require(tools.first { $0.name == name }) }

    for path in ["../outside/secret.txt", "out/secret.txt", "secret-link", folders.outside.path + "/secret.txt"] {
        await #expect(throws: ToolFailure.self) { _ = try await tool("read_file").call(arguments: try json(["path": path])) }
        await #expect(throws: ToolFailure.self) {
            _ = try await tool("edit_file").call(arguments: try json(["path": path, "old_string": "secret", "new_string": "changed"]))
        }
    }
    for path in ["../outside/made.txt", "out/made.txt", "dangling", "out/deep/made.txt", folders.outside.path + "/made.txt"] {
        await #expect(throws: ToolFailure.self) { _ = try await tool("write_file").call(arguments: try json(["path": path, "content": "x"])) }
    }
    for path in ["..", "out", folders.outside.path] {
        await #expect(throws: ToolFailure.self) { _ = try await tool("list_directory").call(arguments: try json(["path": path])) }
    }
    // Nothing outside was made or changed.
    #expect(try folders.outsideNames() == before)
    #expect(try String(contentsOf: folders.outside.appendingPathComponent("secret.txt"), encoding: .utf8) == "secret")
    // And inside they work, through a link that stays inside too.
    #expect(try await tool("read_file").call(arguments: try json(["path": "alias/in.txt"])) == "1\tinside\n")
    _ = try await tool("write_file").call(arguments: try json(["path": "new/deep/made.txt", "content": "made"]))
    #expect(try String(contentsOf: folders.root.appendingPathComponent("new/deep/made.txt"), encoding: .utf8) == "made")
    #expect(try await tool("list_directory").call(arguments: try json(["path": "new"])) == "deep/")
}

// MARK: The read tool's numbers

@Test func readFileTakesAnyOffsetAndLimit() async throws {
    let root = try scratch()
    try "one\ntwo\nthree".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let read = ReadFileTool(cwd: root.path)
    func lines(_ arguments: [String: Any]) async throws -> String {
        var arguments = arguments
        arguments["path"] = "a.txt"
        return try await read.call(arguments: try json(arguments))
    }
    // The largest integers there are: `offset - 1 + limit` overflowed here.
    #expect(try await lines(["offset": 2, "limit": Int.max]) == "2\ttwo\n3\tthree\n")
    #expect(try await lines(["offset": 1, "limit": Int.max]) == "1\tone\n2\ttwo\n3\tthree\n")
    #expect(try await lines(["offset": Int.max, "limit": Int.max]) == "(file has 3 lines)")
    // Below one reads as one.
    #expect(try await lines(["offset": Int.min, "limit": Int.min]) == "1\tone\n… (2 more lines)\n")
    #expect(try await lines(["offset": 0, "limit": 2]) == "1\tone\n2\ttwo\n… (1 more lines)\n")
    // The edges of the file.
    #expect(try await lines(["offset": 3, "limit": 1]) == "3\tthree\n")
    #expect(try await lines(["offset": 3, "limit": 5]) == "3\tthree\n")
    #expect(try await lines(["offset": 4]) == "(file has 3 lines)")
    #expect(try await lines([:]) == "1\tone\n2\ttwo\n3\tthree\n")
}

@Test func readFileCountsAFilesLinesAsAnEditorDoes() async throws {
    let root = try scratch()
    try "one\ntwo\n".write(to: root.appendingPathComponent("ended.txt"), atomically: true, encoding: .utf8)
    try "".write(to: root.appendingPathComponent("empty.txt"), atomically: true, encoding: .utf8)
    try "\n\n".write(to: root.appendingPathComponent("blank.txt"), atomically: true, encoding: .utf8)
    let read = ReadFileTool(cwd: root.path)
    // A file that ends with a newline has two lines, not a third, empty one.
    #expect(try await read.call(arguments: try json(["path": "ended.txt"])) == "1\tone\n2\ttwo\n")
    #expect(try await read.call(arguments: try json(["path": "ended.txt", "offset": 3])) == "(file has 2 lines)")
    #expect(try await read.call(arguments: try json(["path": "empty.txt"])) == "(file has 0 lines)")
    // Blank lines are lines.
    #expect(try await read.call(arguments: try json(["path": "blank.txt"])) == "1\t\n2\t\n")
}

/// A file that cannot be read says why, which is what the model can act on.
@Test func aFileThatCannotBeReadSaysWhy() async throws {
    let root = try scratch()
    try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: root.appendingPathComponent("binary.dat"))
    let read = ReadFileTool(cwd: root.path)
    let missing = await #expect(throws: ToolFailure.self) { _ = try await read.call(arguments: try json(["path": "nowhere.txt"])) }
    let binary = await #expect(throws: ToolFailure.self) { _ = try await read.call(arguments: try json(["path": "binary.dat"])) }
    #expect(missing?.message.hasPrefix("cannot read ") == true)
    #expect(binary?.message.hasPrefix("cannot read ") == true)
    // Two different reasons, each after the path.
    #expect(missing?.message.contains("nowhere.txt: ") == true)
    #expect(binary?.message.contains("binary.dat: ") == true)
    #expect(missing?.message.split(separator: ": ").last != binary?.message.split(separator: ": ").last)
    await #expect(throws: ToolFailure(message: "read_file needs a path")) { _ = try await read.call(arguments: "{}") }
    let listing = await #expect(throws: ToolFailure.self) { _ = try await ListDirectoryTool(cwd: root.path).call(arguments: try json(["path": "nowhere"])) }
    #expect(listing?.message.contains("nowhere: ") == true)
}

@Test func editFileReplacesExactlyOneOccurrence() async throws {
    let root = try scratch()
    let file = root.appendingPathComponent("a.txt")
    try "one two one".write(to: file, atomically: true, encoding: .utf8)
    let edit = EditFileTool(cwd: root.path)
    let full = try CodingTools.resolve("a.txt", in: root.path)
    func arguments(_ old: String, _ new: String) throws -> String { try json(["path": "a.txt", "old_string": old, "new_string": new]) }
    await #expect(throws: ToolFailure(message: "old_string occurs 2 times in \(full); make it unique")) { _ = try await edit.call(arguments: try arguments("one", "1")) }
    await #expect(throws: ToolFailure(message: "old_string not found in \(full)")) { _ = try await edit.call(arguments: try arguments("three", "3")) }
    await #expect(throws: ToolFailure(message: "old_string is empty; give the text to replace")) { _ = try await edit.call(arguments: try arguments("", "x")) }
    await #expect(throws: ToolFailure(message: "edit_file needs path, old_string and new_string")) { _ = try await edit.call(arguments: try json(["path": "a.txt"])) }
    // None of those changed the file.
    #expect(try String(contentsOf: file, encoding: .utf8) == "one two one")
    #expect(try await edit.call(arguments: try arguments("two", "2")) == "edited \(full)")
    #expect(try String(contentsOf: file, encoding: .utf8) == "one 2 one")
}

// MARK: Session ids

@Test(arguments: ["", ".", "..", "../escape", "a/b", "/etc/passwd", ".hidden", "-flag", "has space", "tab\t", "new\nline", "naïve", "~", "a\\b",
                  String(repeating: "a", count: 129)])
func anIdThatIsNotAFileNameIsRefused(id: String) throws {
    let base = try scratch()
    let store = ORSessionStore(directory: base.appendingPathComponent("sessions"))
    #expect(!ORSessionStore.isValid(id: id))
    #expect(throws: ORSessionError.invalidID(id)) { try store.url(for: id) }
    #expect(throws: ORSessionError.invalidID(id)) { try store.logURL(for: id) }
    #expect(throws: ORSessionError.invalidID(id)) { try store.load(id: id) }
    #expect(throws: ORSessionError.invalidID(id)) { try store.save(ORSession(id: id, cwd: "/tmp", model: "m")) }
    #expect(throws: ORSessionError.invalidID(id)) { try store.appendLog(id: id, [ORMessage(role: .user, content: "hi")]) }
    #expect(throws: ORSessionError.invalidID(id)) { try store.remove(id: id) }
    #expect(!store.exists(id: id))
    #expect(store.loggedCount(id: id) == 0)
    // Nothing was written, there or anywhere beside it.
    #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == [])
}

@Test(arguments: ["aaa", "A-b_c.1", "0", "75d697e7-6afb-437d-b509-7385473362ba", String(repeating: "a", count: 128)])
func anIdThatIsAFileNameIsTaken(id: String) throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    #expect(ORSessionStore.isValid(id: id))
    try store.save(ORSession(id: id, cwd: "/tmp", model: "m"))
    try store.appendLog(id: id, [ORMessage(role: .user, content: "hi")])
    #expect(try store.url(for: id).deletingLastPathComponent().path == store.directory.path)
    #expect(try store.load(id: id).id == id)
    #expect(store.loggedCount(id: id) == 1)
    #expect(store.list().map(\.id) == [id])
}

@Test func newIdsAreValid() {
    #expect(ORSessionStore.isValid(id: ORSession.newID()))
}

/// A file in the sessions folder whose name is not an id is not a session.
@Test func aStrayFileIsNotListed() throws {
    let store = ORSessionStore(directory: try scratch().appendingPathComponent("sessions"))
    try store.save(ORSession(id: "real", cwd: "/tmp", model: "m"))
    try Data("{}".utf8).write(to: store.directory.appendingPathComponent(".hidden.json"))
    try Data("not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
    #expect(store.list().map(\.id) == ["real"])
}

/// A "/" with a combining mark after it is one character to Swift and
/// still a separator to the system: paths are split as the system splits
/// them, so a link out followed by such a name is still a way out.
@Test func aSeparatorWithACombiningMarkIsStillASeparator() async throws {
    let folders = try Folders()
    let before = try folders.outsideNames()
    #expect(throws: ToolFailure.self) { try CodingTools.resolve("out/\u{301}x", in: folders.root.path) }
    await #expect(throws: ToolFailure.self) {
        _ = try await WriteFileTool(cwd: folders.root.path).call(arguments: try json(["path": "out/\u{301}x", "content": "escaped"]))
    }
    #expect(try folders.outsideNames() == before)
}
