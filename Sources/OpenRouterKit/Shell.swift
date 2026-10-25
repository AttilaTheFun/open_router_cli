// A shell command run to its end, however it ends: by itself, at its
// deadline, or because the caller was cancelled. Whichever it is, `run`
// returns — nothing here waits on a thing that may never happen.
//
// What can happen to a running command arrives as one stream of events
// (output, the end of output, the exit, a reason to stop it, two timers),
// read by one loop that holds all the state, so there is nothing shared
// to lock.

import Foundation

/// How a command ended, and what it printed.
struct ShellOutcome: Sendable {
    /// Why a command was stopped, when it did not end by itself.
    enum Stop: Sendable {
        /// It ran past its timeout.
        case deadline
        /// The task that asked for it was cancelled.
        case cancelled
    }

    /// What it printed, stdout and stderr together, up to the bytes asked
    /// to be kept.
    var output = Data()
    /// How many bytes it printed beyond those.
    var dropped = 0
    var stopped: Stop?
    /// The exit status, or the signal's number when `signalled`.
    var status: Int32 = 0
    var signalled = false
}

enum Shell {
    /// How long a stopped command has to end after being asked (SIGTERM)
    /// before it is made to (SIGKILL).
    static let patience: Duration = .seconds(2)
    /// How long output is still read after the shell has exited without
    /// the pipe closing: something it left running in the background
    /// holds the pipe open, and may hold it for ever.
    static let grace: Duration = .milliseconds(250)

    private enum Event: Sendable {
        case output(Data)
        case endOfOutput
        case exited(SpawnedProcess.Ending)
        case stop(ShellOutcome.Stop)
        /// `patience` has passed since the command was asked to end.
        case insist
        /// `grace` has passed since the shell exited.
        case graceOver
    }

    /// The shell commands run in: zsh where there is one (macOS's own),
    /// else bash (a Linux's), else sh.
    static let shell = ["/bin/zsh", "/bin/bash", "/bin/sh"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/sh"

    /// Runs `command` with `<shell> -lc` in `cwd`, with no input and in
    /// `environment` (this process's own when nil), and returns when the
    /// shell has exited and its output has been read. Past `timeout`, or
    /// when the calling task is cancelled, the command is stopped: the
    /// outcome says which.
    static func run(_ command: String, cwd: String, environment: [String: String]?, timeout: Duration, keep: Int) async throws -> ShellOutcome {
        // A task already cancelled starts nothing.
        try Task.checkCancellation()
        let process: SpawnedProcess
        do {
            process = try SpawnedProcess.spawn(shell, ["-lc", command], cwd: cwd, environment: environment ?? ProcessInfo.processInfo.environment)
        } catch {
            throw ToolFailure(message: "could not run: \(error)")
        }

        let (events, feed) = AsyncStream.makeStream(of: Event.self)
        // The output and the end are waited for on threads of their own:
        // both block, and neither may hold up the tasks' shared threads.
        let output = process.output
        Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
                if count > 0 {
                    feed.yield(.output(Data(buffer[0..<count])))
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(output)
            feed.yield(.endOfOutput)
        }.start()
        Thread { feed.yield(.exited(process.wait())) }.start()
        // The shell leads a process group of its own (SpawnedProcess); a
        // signal to the group reaches what it started as well. Checked
        // rather than assumed: the group is signalled only if the shell
        // was seen to lead it. (The usual limit of signalling by number
        // holds: once the shell and everything it started are gone, the
        // number is the system's to give again.)
        let pid = process.pid
        let target = Target(pid: pid, isGroup: getpgid(pid) == pid)

        // Followed in a task of its own, which the caller's cancellation
        // does not cancel: a cancelled caller must stop the command and
        // still wait for it to be gone, not walk away from it.
        let following = Task { await follow(events, feed: feed, target: target, timeout: timeout, keep: keep) }
        let outcome = await withTaskCancellationHandler {
            await following.value
        } onCancel: {
            feed.yield(.stop(.cancelled))
        }
        feed.finish()
        return outcome
    }

    /// What signals go to: the shell's process group, or the shell alone.
    private struct Target: Sendable {
        let pid: pid_t
        let isGroup: Bool

        func signal(_ signal: Int32) {
            _ = kill(isGroup ? -pid : pid, signal)
        }
    }

    private static func follow(_ events: AsyncStream<Event>, feed: AsyncStream<Event>.Continuation, target: Target,
                               timeout: Duration, keep: Int) async -> ShellOutcome {
        var outcome = ShellOutcome()
        var exited = false
        var outputEnded = false
        await withTaskGroup(of: Void.self) { timers in
            timers.addTask {
                do { try await Task.sleep(for: timeout) } catch { return }
                feed.yield(.stop(.deadline))
            }
            loop: for await event in events {
                switch event {
                case .output(let data):
                    let kept = data.prefix(max(0, keep - outcome.output.count))
                    outcome.output.append(kept)
                    outcome.dropped += data.count - kept.count
                case .endOfOutput:
                    outputEnded = true
                    if exited { break loop }
                case .exited(let ending):
                    exited = true
                    outcome.status = ending.status
                    outcome.signalled = ending.signalled
                    // A stopped command's stragglers (what ignored the
                    // request to end, or outlived the shell) go with it.
                    if outcome.stopped != nil, target.isGroup { target.signal(SIGKILL) }
                    if outputEnded { break loop }
                    timers.addTask {
                        do { try await Task.sleep(for: grace) } catch { return }
                        feed.yield(.graceOver)
                    }
                case .graceOver:
                    break loop
                case .stop(let reason):
                    guard outcome.stopped == nil, !exited else { continue }
                    outcome.stopped = reason
                    target.signal(SIGTERM)
                    timers.addTask {
                        do { try await Task.sleep(for: patience) } catch { return }
                        feed.yield(.insist)
                    }
                case .insist:
                    if !exited { target.signal(SIGKILL) }
                }
            }
            timers.cancelAll()
        }
        return outcome
    }
}
