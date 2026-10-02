// The bash tool returns, whatever the command does: leaves something
// running, prints more than a pipe holds, outlives its timeout, or is
// cancelled. Each test would hang (or wait out a long sleep) otherwise,
// so each has a time limit, and the ones about a command that must be
// stopped check how long the call took.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

/// The bash tool in a folder, with an environment in which the login
/// shell reads nobody's start-up files (`ZDOTDIR` is an empty folder):
/// what a command prints, and how long the shell takes to start, do not
/// depend on whose computer this is.
private func bash(in cwd: String) throws -> BashTool {
    let quiet = ProcessInfo.processInfo.environment.merging(["ZDOTDIR": try scratch().path]) { $1 }
    return BashTool(cwd: cwd, environment: quiet)
}

private func json(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// Whether a process with this id exists.
private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

/// The process id a command printed as its first line.
private func firstPID(in output: String) throws -> pid_t {
    let line = try #require(output.split(separator: "\n").first)
    return try #require(pid_t(String(line)))
}

/// Waits (up to two seconds) for a process to be gone.
private func isGone(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<40 where isAlive(pid) { try await Task.sleep(for: .milliseconds(50)) }
    return !isAlive(pid)
}

@Test(.timeLimit(.minutes(1))) func bashReportsOutputAndExitStatus() async throws {
    let ran = try await bash(in: try scratch().path).call(arguments: try json(["command": "echo out; echo err >&2; exit 3"]))
    #expect(ran == "out\nerr\n\n[exit 3]")
}

@Test(.timeLimit(.minutes(1))) func bashRunsInTheWorkingDirectory() async throws {
    let cwd = try scratch().path
    let ran = try await bash(in: cwd).call(arguments: try json(["command": "pwd -P"]))
    let real = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
    #expect(ran.hasPrefix(real + "\n") || ran.hasPrefix("/private" + real + "\n"))
}

@Test(.timeLimit(.minutes(1))) func bashNeedsACommand() async throws {
    await #expect(throws: ToolFailure(message: "bash needs a command")) { _ = try await bash(in: try scratch().path).call(arguments: "{}") }
}

/// A command that leaves a job running returns when the shell exits: the
/// job holds the output pipe open, and reading to its end would wait for
/// the job.
@Test(.timeLimit(.minutes(1))) func bashReturnsWhenTheCommandLeavesAJobRunning() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let ran = try await bash(in: try scratch().path).call(arguments: try json(["command": "sleep 30 & echo $!"]))
    #expect(clock.now - start < .seconds(10))
    let lines = ran.split(separator: "\n")
    let job = try firstPID(in: ran)
    #expect(lines.last == "[exit 0]")
    // The job is the command's business: it is left running.
    #expect(isAlive(job))
    kill(job, SIGKILL)
}

/// More output than a pipe holds neither blocks the command nor is kept
/// whole, and the exit status survives the cut.
@Test(.timeLimit(.minutes(1))) func bashCutsLongOutputAndKeepsTheStatus() async throws {
    let ran = try await bash(in: try scratch().path).call(arguments: try json(["command": "head -c 5000000 /dev/zero | tr '\\0' 'x'; exit 7"]))
    #expect(ran.hasPrefix(String(repeating: "x", count: CodingTools.outputLimit)))
    #expect(ran.hasSuffix("\n… (\(5_000_000 - CodingTools.outputLimit) more bytes truncated)\n[exit 7]"))
    #expect(ran.utf8.count < CodingTools.outputLimit + 100)
}

/// Past its timeout a command is killed, with what it started.
@Test(.timeLimit(.minutes(1))) func bashKillsACommandAtItsTimeout() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let ran = try await bash(in: try scratch().path).call(arguments: try json(["command": "sleep 30 & echo $!; sleep 30", "timeout": 2]))
    #expect(clock.now - start < .seconds(10))
    let lines = ran.split(separator: "\n")
    let job = try firstPID(in: ran)
    #expect(lines.dropFirst().first == "(killed after 2s)")
    #expect(lines.last == "[signal \(SIGTERM)]")
    #expect(try await isGone(job))
}

/// A command that ignores the request to end is made to.
@Test(.timeLimit(.minutes(1))) func bashKillsACommandThatIgnoresTheRequest() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let ran = try await bash(in: try scratch().path).call(arguments: try json(["command": "trap '' TERM; echo waiting; while true; do sleep 1; done", "timeout": 2]))
    #expect(clock.now - start < .seconds(15))
    #expect(ran == "waiting\n\n(killed after 2s)\n[signal \(SIGKILL)]")
}

/// Cancelling the task that called the tool stops the command: the call
/// returns with what was printed, and says it was interrupted.
@Test(.timeLimit(.minutes(1))) func bashStopsWhenItsTaskIsCancelled() async throws {
    let cwd = try scratch()
    let started = cwd.appendingPathComponent("started")
    let clock = ContinuousClock()
    let start = clock.now
    let call = Task { try await bash(in: cwd.path).call(arguments: try json(["command": "echo $$ | tee started; sleep 30"])) }
    // The command says when it is running; then the cancellation.
    while (try? String(contentsOf: started, encoding: .utf8))?.hasSuffix("\n") != true {
        try await Task.sleep(for: .milliseconds(20))
    }
    call.cancel()
    let ran = try await call.value
    #expect(clock.now - start < .seconds(15))
    let lines = ran.split(separator: "\n")
    let shell = try firstPID(in: ran)
    #expect(lines.dropFirst().first == "(interrupted)")
    #expect(try await isGone(shell))
}

/// A call from a task that is already cancelled starts no command.
@Test(.timeLimit(.minutes(1))) func bashStartsNothingForACancelledTask() async throws {
    let cwd = try scratch()
    let (gate, _) = AsyncStream.makeStream(of: Void.self)
    let call = Task {
        for await _ in gate {}
        return try await bash(in: cwd.path).call(arguments: try json(["command": "touch ran"]))
    }
    call.cancel()
    await #expect(throws: CancellationError.self) { _ = try await call.value }
    #expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("ran").path))
}

@Test(.timeLimit(.minutes(1))) func bashSaysWhenItCannotRun() async throws {
    let failure = await #expect(throws: ToolFailure.self) {
        _ = try await bash(in: "/nonexistent-" + UUID().uuidString).call(arguments: try json(["command": "true"]))
    }
    #expect(failure?.message.hasPrefix("could not run: ") == true)
}

/// The command runs in the environment it is given.
@Test(.timeLimit(.minutes(1))) func bashRunsInTheEnvironmentItIsGiven() async throws {
    let cwd = try scratch().path
    let environment = ProcessInfo.processInfo.environment.merging(["ZDOTDIR": try scratch().path, "OPENROUTER_TEST_VALUE": "given"]) { $1 }
    let ran = try await BashTool(cwd: cwd, environment: environment).call(arguments: try json(["command": "echo $OPENROUTER_TEST_VALUE"]))
    #expect(ran == "given\n\n[exit 0]")
}
