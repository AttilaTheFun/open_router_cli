// A command's shell, started with posix_spawn as the leader of a process
// group of its own, its stdout and stderr together on one pipe and its
// stdin the null device; its end learned from waitpid.
//
// Foundation's `Process` would do, but Linux's learns that a process has
// ended only once everything it started has let go of a socket it hands
// down: a command that left a job running seemed to run until the job
// ended, and a timeout could not end it.

import Foundation

struct SpawnedProcess: Sendable {
    let pid: pid_t
    /// The read end of the output pipe, the caller's to read and close.
    let output: Int32

    /// How a process ended: its exit status, or the signal that ended it.
    struct Ending: Sendable {
        let status: Int32
        let signalled: Bool
    }

    struct Failure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Starts `path` with `arguments` in `cwd` and `environment`.
    static func spawn(_ path: String, _ arguments: [String], cwd: String, environment: [String: String]) throws -> SpawnedProcess {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw Failure(call: "pipe", code: errno) }
        let (reading, writing) = (ends[0], ends[1])
        // The read end stays here: closed in the child as it starts.
        _ = fcntl(reading, F_SETFD, FD_CLOEXEC)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = spawning(posix_spawn_file_actions_init, posix_spawn_file_actions_destroy) { actions in
            posix_spawn_file_actions_addopen(actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(actions, writing, 1)
            posix_spawn_file_actions_adddup2(actions, writing, 2)
            posix_spawn_file_actions_addclose(actions, writing)
            posix_spawn_file_actions_addchdir_np(actions, cwd)
            return spawning(posix_spawnattr_init, posix_spawnattr_destroy) { attributes in
                // A group of its own, so a signal to the group reaches what
                // the shell starts; signals as they are by default, none
                // blocked, whatever this process does with them (SIGPIPE).
                var defaults = sigset_t()
                sigfillset(&defaults)
                sigdelset(&defaults, SIGKILL)
                sigdelset(&defaults, SIGSTOP)
                var unblocked = sigset_t()
                sigemptyset(&unblocked)
                posix_spawnattr_setsigdefault(attributes, &defaults)
                posix_spawnattr_setsigmask(attributes, &unblocked)
                posix_spawnattr_setpgroup(attributes, 0)
                posix_spawnattr_setflags(attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
                return posix_spawn(&pid, path, actions, attributes, argv, envp)
            }
        }
        close(writing)
        guard code == 0 else {
            close(reading)
            throw Failure(call: "posix_spawn", code: code)
        }
        return SpawnedProcess(pid: pid, output: reading)
    }

    /// A spawn's file actions or attributes, made and let go of around
    /// `body`. Their type is whatever the system's functions take (a
    /// pointer on Apple's systems, a structure on Linux), read from those.
    private static func spawning<Storage>(_ make: (UnsafeMutablePointer<Storage>) -> Int32,
                                          _ letGo: (UnsafeMutablePointer<Storage>) -> Int32,
                                          _ body: (UnsafeMutablePointer<Storage>) -> Int32) -> Int32 {
        let storage = UnsafeMutablePointer<Storage>.allocate(capacity: 1)
        defer { storage.deallocate() }
        guard make(storage) == 0 else { return errno }
        defer { _ = letGo(storage) }
        return body(storage)
    }

    /// Blocks until the process has ended, and says how.
    func wait() -> Ending {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return Ending(status: -1, signalled: false) }
        }
        // As the system's WIFSIGNALED, WTERMSIG and WEXITSTATUS read it.
        let signal = status & 0x7f
        if signal != 0 && signal != 0x7f { return Ending(status: signal, signalled: true) }
        return Ending(status: (status >> 8) & 0xff, signalled: false)
    }
}
