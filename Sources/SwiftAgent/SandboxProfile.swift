import Foundation

/// Generates and materializes the SBPL profile used by ProcessRunner (FR-22).
///
/// Smoke-tested live on macOS 26.6.2 (2026-08-26):
/// - `(param "…")` substitution works via `-D KEY=value` (a bare identifier does not).
/// - Startup aborts with SIGABRT in dyld unless reads include the root directory
///   itself: `(allow file-read* (literal "/"))`. dyld opens "/" during ignition.
enum SandboxProfile {
    struct Paths: Sendable, Equatable {
        var workingDir: String
        /// Write access is limited to WORKING_DIR/tmp (FR-22), canonicalized
        /// because SBPL resolves no symlinks ("/tmp" would silently deny writes).
        var workingTmp: String { workingDir.hasSuffix("/") ? workingDir + "tmp" : workingDir + "/tmp" }

        init(workingDir: String) {
            // SBPL matches literal paths only: /var/folders/... must become
            // /private/var/folders/... before it lands in the profile.
            // Foundation's resolvers leave /var alone; realpath does not.
            if let resolved = realpath(workingDir, nil) {
                self.workingDir = String(cString: resolved)
                free(resolved)
            } else {
                self.workingDir = workingDir
            }
        }
    }

    nonisolated static let sandboxExecPath = "/usr/bin/sandbox-exec"
    nonisolated static let zshPath = "/bin/zsh"

    static func text(for paths: Paths) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        (version 1)
        (deny default)

        (allow process-exec)
        (allow process-fork)
        (allow sysctl-read)
        (allow mach-lookup)

        (allow file-read*
            (literal "/")
            (subpath "/usr")
            (subpath "/bin")
            (subpath "/sbin")
            (subpath "/System")
            (subpath "/Library")
            (subpath "/etc")
            (subpath "/private/etc")
            (subpath "/private/var/db/dyld")
            (subpath "/dev")
            (subpath "/System/Volumes/Preboot")
            (subpath "/private/preboot")
            (subpath (param "WORKING_DIR")))

        (allow file-write*
            (subpath (param "WORKING_TMP"))
            (literal "/dev/null"))

        (deny network*)

        ; Explicit sensitive paths (FR-22). Redundant today: WORKING_DIR is the
        ; only user-writable read area, but stays as defense in depth.
        (deny file-read* (subpath "\(home)/.ssh"))
        (deny file-read* (subpath "\(home)/.aws"))
        (deny file-read* (subpath "\(home)/Library/Keychains"))
        (deny file-read* (subpath "\(home)/Documents"))
        """
    }

    static func write(to url: URL, paths: Paths) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text(for: paths).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Cheap liveness probe: runs /bin/echo under the profile. Returns nil when
    /// sandbox-exec is unavailable or broken; a message when the probe fails.
    static func smokeTest(paths: Paths) async -> SandboxSmokeOutcome {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-sandbox-\(UUID().uuidString).sb")
        do {
            try write(to: fileURL, paths: paths)
        } catch {
            return .failure("profile write failed: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let runner = ProcessRunner(timeout: 15)
        let result = await runner.run(
            executable: zshPath,
            arguments: ["-c", "echo ok"],
            environment: [:],
            sandbox: .sandbox(profileFileURL: fileURL, paths: paths)
        )
        switch result.outcome {
        case .completed:
            guard result.exitCode == 0 else {
                return .failure("probe exited \(result.exitCode.map(String.init) ?? "?")")
            }
            if case .deniedSandbox = result.sandboxVerdict { return .failure("sandbox denied probe") }
            return .ok
        case .failedToLaunch(let error):
            return .failure("sandbox-exec unavailable: \(error)")
        case .timedOut:
            return .failure("probe timed out")
        }
    }
}

/// String cannot conform to Error cheaply; dedicated outcome type instead.
enum SandboxSmokeOutcome: Sendable {
    case ok
    case failure(String)
}
