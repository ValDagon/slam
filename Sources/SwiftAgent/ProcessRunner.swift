import Foundation

/// How the command is wrapped at spawn time.
enum SandboxInvocation: Sendable {
    /// Plain Foundation.Process spawn (used by tests and non-sandboxed mode).
    case none
    /// `/usr/bin/sandbox-exec -D WORKING_DIR=… -D WORKING_TMP=… -f <profile>` + zsh -c.
    case sandbox(profileFileURL: URL, paths: SandboxProfile.Paths)
}

/// Outcome of one ProcessRunner run, including the SBPL-specific verdict.
struct ProcessResult: Sendable {
    enum Outcome: Sendable {
        case completed
        case failedToLaunch(Error)
        case timedOut
    }

    /// Why the sandboxed process died when the exit status is a signal.
    enum SandboxVerdict: Sendable, Equatable {
        case ran
        /// SIGTRAP/SIGKILL under an active profile — Seatbelt rejected the operation.
        case deniedSandbox(signal: Int32)
    }

    let outcome: Outcome
    let exitCode: Int32?
    let exitSignal: Int32?
    let stdout: String
    let stderr: String
    let sandboxVerdict: SandboxVerdict
    let truncated: Bool

    var succeeded: Bool {
        if case .completed = outcome { return exitCode == 0 }
        return false
    }
}

/// Runs commands via Foundation.Process, optionally wrapped in sandbox-exec.
///
/// QoS .utility per spec §2; pipes are drained concurrently so large output
/// cannot deadlock; the timeout kill uses SIGTERM then SIGKILL after grace.
/// Blocking calls are confined to Process bookkeeping, which is unavoidable.
struct ProcessRunner: Sendable {
    struct Config: Sendable {
        var timeout: TimeInterval
        var maxOutputBytes: Int
        var terminationGrace: TimeInterval

        init(timeout: TimeInterval = 30, maxOutputBytes: Int = 16 * 1024, terminationGrace: TimeInterval = 3) {
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.terminationGrace = terminationGrace
        }
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    init(timeout: TimeInterval) {
        self.config = Config(timeout: timeout)
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        sandbox: SandboxInvocation = .none
    ) async -> ProcessResult {
        let process = Process()
        var argv: [String]
        switch sandbox {
        case .none:
            process.executableURL = URL(fileURLWithPath: executable)
            argv = arguments
        case .sandbox(let profileFileURL, let paths):
            process.executableURL = URL(fileURLWithPath: SandboxProfile.sandboxExecPath)
            argv = [
                "-D", "WORKING_DIR=\(paths.workingDir)",
                "-D", "WORKING_TMP=\(paths.workingTmp)",
                "-f", profileFileURL.path,
                executable,
            ] + arguments
        }
        process.arguments = argv
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        // Deliberately minimal environment: no inherited secrets or proxy vars.
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(
                outcome: .failedToLaunch(error),
                exitCode: nil,
                exitSignal: nil,
                stdout: "",
                stderr: "",
                sandboxVerdict: .ran,
                truncated: false
            )
        }

        async let stdoutTask = Self.drain(stdoutPipe.fileHandleForReading, maxBytes: config.maxOutputBytes)
        async let stderrTask = Self.drain(stderrPipe.fileHandleForReading, maxBytes: config.maxOutputBytes)

        let clock = ContinuousClock()
        let deadline = clock.now + Duration.seconds(config.timeout)
        let waitTask = Task.detached(priority: .utility) { process.waitUntilExit() }
        var timedOut = false

        while true {
            if waitTask.isCancelled { break }
            if process.isRunning {
                if clock.now >= deadline {
                    timedOut = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                _ = await waitTask.result
                break
            }
        }

        if timedOut {
            waitTask.cancel()
            Self.terminate(process: process, grace: config.terminationGrace)
        }

        let outputs = await (stdoutTask, stderrTask)
        let exitStatus = process.terminationStatus
        let bySignal = process.terminationReason == .uncaughtSignal
        let signal = bySignal ? exitStatus : nil

        let verdict: ProcessResult.SandboxVerdict
        if bySignal, case .sandbox = sandbox, signal == SIGTRAP || signal == SIGKILL {
            verdict = .deniedSandbox(signal: signal!)
        } else {
            verdict = .ran
        }

        return ProcessResult(
            outcome: timedOut ? .timedOut : .completed,
            exitCode: timedOut ? nil : exitStatus,
            exitSignal: signal,
            stdout: outputs.0.text,
            stderr: outputs.1.text,
            sandboxVerdict: verdict,
            truncated: outputs.0.truncated || outputs.1.truncated
        )
    }

    /// Reads to EOF with a hard byte cap; returns text plus whether it was cut.
    private static func drain(_ handle: FileHandle, maxBytes: Int) async -> (text: String, truncated: Bool) {
        handle.readabilityHandler = { _ in }
        defer { handle.readabilityHandler = nil }
        var data = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < maxBytes {
                let room = maxBytes - data.count
                data.append(chunk.prefix(room))
                if chunk.count > room {
                    // Drain the rest so the child never blocks on a full pipe.
                    while !(handle.availableData.isEmpty) {}
                    break
                }
            } else {
                while !(handle.availableData.isEmpty) {}
                break
            }
        }
        return (String(decoding: data, as: UTF8.self), data.count >= maxBytes)
    }

    private static func terminate(process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
