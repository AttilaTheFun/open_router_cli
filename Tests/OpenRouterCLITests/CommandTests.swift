// The built `openrouter`, run as a host or a person runs it: what it
// prints and how it exits. Every run has a home folder of its own with a
// fresh model list in it and no key anywhere, so nothing reaches the
// network: these are the paths that end before a model is asked.

import Foundation
import Testing

/// What a run printed, and how it exited.
private struct Run {
    let status: Int32
    let out: String
    let err: String

    var lines: [[String: Any]] {
        out.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
}

/// A class of this test bundle, for finding the bundle by.
private final class InThisBundle {}

/// The executable, beside the test bundle that was built with it.
private func executable() throws -> URL {
    let built = Bundle(for: InThisBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("openrouter")
    try #require(FileManager.default.isExecutableFile(atPath: built.path), "no openrouter at \(built.path)")
    return built
}

/// Runs `openrouter` with these arguments and this text on stdin, in a
/// home of its own.
private func openrouter(_ arguments: [String], stdin: String = "") async throws -> Run {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-cli-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // A model list fetched just now: a run has no reason to fetch another.
    try Data(#"{"fetched":\#(Date().timeIntervalSince1970),"models":[]}"#.utf8).write(to: home.appendingPathComponent("models.json"))
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasSuffix("API_KEY") }
    environment["OPENROUTER_HOME"] = home.path

    let process = Process()
    process.executableURL = try executable()
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = home
    let (input, out, err) = (Pipe(), Pipe(), Pipe())
    process.standardInput = input
    process.standardOutput = out
    process.standardError = err
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    return Run(status: status,
               out: String(decoding: try out.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self),
               err: String(decoding: try err.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self))
}

private let noKey = "No OpenRouter API key. Run `openrouter auth login <key>` on this computer (keys: https://openrouter.ai/keys), or set OPENROUTER_API_KEY."

@Test(.timeLimit(.minutes(1))) func aOneShotTurnThatFailsExitsOne() async throws {
    let stream = try await openrouter(["-p", "--output-format", "stream-json", "--session-id", "named", "hi"])
    #expect(stream.status == 1)
    #expect(stream.err == "")
    #expect(stream.lines.map { $0["type"] as? String } == ["system", "result"])
    let first = try #require(stream.lines.first)
    #expect(first["subtype"] as? String == "init")
    #expect(first["session_id"] as? String == "named")
    #expect(first["model"] as? String == "openai/gpt-5-nano")
    #expect(first["tools"] as? [String] == ["bash", "read_file", "write_file", "edit_file", "list_directory"])
    #expect(first["permissionMode"] as? String == "bypassPermissions")
    #expect(stream.lines[1]["is_error"] as? Bool == true)
    #expect(stream.lines[1]["result"] as? String == noKey)
    #expect(stream.lines[1]["session_id"] as? String == "named")

    let text = try await openrouter(["-p", "hi"])
    #expect(text.status == 1)
    #expect(text.out == "")
    #expect(text.err == noKey + "\n")
}

/// The command line Visor runs, in its manual mode: the session starts,
/// the options that change nothing are noted on stderr, each control
/// request is answered, and the end of stdin ends the run with 0.
@Test(.timeLimit(.minutes(1))) func aHostsSessionStartsAnswersAndEnds() async throws {
    let run = try await openrouter(
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--mcp-config", #"{"mcpServers":{}}"#, "--permission-mode", "acceptEdits", "--permission-prompt-tool", "mcp__visor__approve",
         "--model", "a/b", "--effort", "high"],
        stdin: """
            {"type":"control_request","request_id":"init-1","request":{"subtype":"initialize"}}
            {"type":"control_request","request_id":"int-1","request":{"subtype":"interrupt"}}
            {"type":"user","message":{"role":"user","content":"hello"}}

            """)
    #expect(run.status == 0)
    #expect(run.lines.map { $0["type"] as? String } == ["system", "control_response", "control_response", "result"])
    #expect(run.lines[0]["model"] as? String == "a/b")
    #expect((run.lines[1]["response"] as? [String: String])?["subtype"] == "error")
    #expect(run.lines[2]["response"] as? [String: String] == ["request_id": "int-1", "subtype": "success"])
    #expect(run.lines[3]["result"] as? String == noKey)
    #expect(run.err.split(separator: "\n").map(String.init) == [
        "openrouter: --permission-mode acceptEdits is not enforced: openrouter has one mode, and in it tools run without asking.",
        "openrouter: --permission-prompt-tool is not used: openrouter's tools run without asking, and mcp__visor__approve is never asked.",
        "openrouter: --mcp-config is not used: openrouter does not connect to MCP servers, and the model is not offered their tools.",
    ])
}

@Test(.timeLimit(.minutes(1))) func aBadCommandLineExitsTwo() async throws {
    let unknown = try await openrouter(["-p", "--nonsense", "hi"])
    #expect(unknown.status == 2)
    #expect(unknown.out == "")
    #expect(unknown.err == "openrouter: --nonsense is not an option openrouter takes (openrouter --help lists the options)\n")

    let nothing = try await openrouter(["-p"])
    #expect(nothing.status == 2)
    #expect(nothing.err == "openrouter: nothing to say: give a prompt, or pipe one in.\n")

    let resume = try await openrouter(["resume"])
    #expect(resume.status == 2)
    #expect(resume.err == "openrouter: resume needs a session id (openrouter sessions lists them)\n")
}

/// A session that cannot be opened is said to be, in the shape asked for.
@Test(.timeLimit(.minutes(1))) func aSessionThatCannotBeOpenedExitsOne() async throws {
    let missing = try await openrouter(["-p", "--output-format", "stream-json", "--resume", "no-such-session", "hi"])
    #expect(missing.status == 1)
    #expect(missing.lines.count == 1)
    #expect(missing.lines.first?["is_error"] as? Bool == true)
    #expect(missing.lines.first?["session_id"] as? String == "no-such-session")
    #expect((missing.lines.first?["result"] as? String)?.hasPrefix("Could not open the session: ") == true)

    let bad = try await openrouter(["-p", "--resume", "../escape", "hi"])
    #expect(bad.status == 1)
    #expect(bad.err.hasPrefix("Could not open the session: \"../escape\" is not a session id"))
}

@Test(.timeLimit(.minutes(1))) func theCommandsThatAskNothingOfAModel() async throws {
    let version = try await openrouter(["--version"])
    #expect(version.status == 0)
    #expect(version.out.split(separator: ".").count == 3)
    #expect(try await openrouter(["version"]).out == version.out)

    let help = try await openrouter(["-h"])
    #expect(help.status == 0)
    #expect(help.out.hasPrefix("openrouter \(version.out.trimmingCharacters(in: .newlines)) — a coding agent on OpenRouter's models\n"))
    #expect(try await openrouter(["help"]).out == help.out)
    #expect(try await openrouter(["--help"]).out == help.out)

    let sessions = try await openrouter(["sessions", "--json"])
    #expect(sessions.status == 0)
    #expect(sessions.out == "[]\n")
    #expect(try await openrouter(["sessions"]).out == "No sessions yet.\n")

    let status = try await openrouter(["auth", "status"])
    #expect(status.status == 1)
    #expect(status.out == "Not logged in. Run `openrouter auth login` or set OPENROUTER_API_KEY.\n")
    let auth = try await openrouter(["auth", "nonsense"])
    #expect(auth.status == 2)
}

/// A message with a line separator in its text is one line of stdin, and
/// one turn: read with Foundation's lines it was two halves, neither of
/// them JSON, and the host waited on a turn that never ran.
@Test(.timeLimit(.minutes(1))) func aMessageWithALineSeparatorInItIsOneMessage() async throws {
    let run = try await openrouter(["-p", "--input-format", "stream-json", "--output-format", "stream-json"],
                                   stdin: "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"one\u{2028}two\"}}\n")
    #expect(run.status == 0)
    #expect(run.err == "")
    #expect(run.lines.map { $0["type"] as? String } == ["system", "result"])
    #expect(run.lines.last?["result"] as? String == noKey)
}
