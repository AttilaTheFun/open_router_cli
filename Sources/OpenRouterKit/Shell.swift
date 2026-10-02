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
        case exited
        case stop(ShellOutcome.Stop)
        /// `patience` has passed since the command was asked to end.
        case insist
        /// `grace` has passed since the shell exited.
        case graceOver
    }

    /// Runs `command` with `zsh -lc` in `cwd`, with no input, and returns
    /// when the shell has exited and its output has been read. Past
    /// `timeout`, or when the calling task is cancelled, the command is
    /// stopped: the outcome says which.
    static func run(_ command: String, cwd: String, timeout: Duration, keep: Int) async throws -> ShellOutcome {
        // A task already cancelled starts nothing.
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let (events, feed) = AsyncStream.makeStream(of: Event.self)
        let reading = pipe.fileHandleForReading
        // Called when the pipe has something: `availableData` does not
        // block here, and is empty at the end of the output.
        reading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                feed.yield(.endOfOutput)
            } else {
                feed.yield(.output(data))
            }
        }
        process.terminationHandler = { _ in feed.yield(.exited) }
        do {
            try process.run()
        } catch {
            reading.readabilityHandler = nil
            throw ToolFailure(message: "could not run: \(error.localizedDescription)")
        }
        // Foundation starts a process as the leader of a process group of
        // its own; a signal to the group reaches what the shell started
        // as well. Checked rather than assumed: the group is signalled
        // only if the shell was seen to lead it. (The usual limit of
        // signalling by number holds: once the shell and everything it
        // started are gone, the number is the system's to give again.)
        let pid = process.processIdentifier
        let target = Target(pid: pid, isGroup: getpgid(pid) == pid)

        // Followed in a task of its own, which the caller's cancellation
        // does not cancel: a cancelled caller must stop the command and
        // still wait for it to be gone, not walk away from it.
        let following = Task { await follow(events, feed: feed, target: target, timeout: timeout, keep: keep) }
        var outcome = await withTaskCancellationHandler {
            await following.value
        } onCancel: {
            feed.yield(.stop(.cancelled))
        }
        feed.finish()
        reading.readabilityHandler = nil
        outcome.status = process.terminationStatus
        outcome.signalled = process.terminationReason == .uncaughtSignal
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
                case .exited:
                    exited = true
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
