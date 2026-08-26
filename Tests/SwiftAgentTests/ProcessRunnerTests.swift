import Foundation
import Testing
@testable import SwiftAgent

/// Stage 4 execution tests. Sandbox cases run the real /usr/bin/sandbox-exec:
/// they double as the CI-visible part of the FR-24 smoke requirement.
@Suite struct ProcessRunnerTests {
    private func tempWorkspace() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slam-sbx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }

    // MARK: - Plain execution

    @Test func plainEchoSucceeds() async {
        let runner = ProcessRunner(timeout: 15)
        let result = await runner.run(executable: "/bin/echo", arguments: ["hi"], environment: [:])
        #expect(result.succeeded)
        #expect(result.stdout == "hi\n")
        #expect(result.exitCode == 0)
    }

    @Test func exitCodeIsCaptured() async {
        let runner = ProcessRunner(timeout: 15)
        let result = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "exit 3"],
            environment: [:]
        )
        #expect(!result.succeeded)
        #expect(result.exitCode == 3)
    }

    @Test func stderrIsSeparatedFromStdout() async {
        let runner = ProcessRunner(timeout: 15)
        let result = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "echo out; echo err >&2"],
            environment: [:]
        )
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test func timeoutKillsHangingCommand() async {
        let runner = ProcessRunner(config: .init(timeout: 1, terminationGrace: 2))
        let started = Date()
        let result = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "sleep 30"],
            environment: [:]
        )
        let elapsed = Date().timeIntervalSince(started)
        if case .timedOut = result.outcome {} else {
            Issue.record("expected timeout outcome")
        }
        #expect(elapsed < 10)
    }

    @Test func outputIsCappedAtMaxBytes() async {
        let runner = ProcessRunner(config: .init(timeout: 15, maxOutputBytes: 1000))
        let result = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "yes | head -c 100000"],
            environment: [:]
        )
        #expect(result.truncated)
        #expect(result.stdout.utf8.count <= 1001)
    }

    // MARK: - Sandboxed execution (live sandbox-exec, macOS only)

    @Test func sandboxedEchoRunsAndWorkspaceWriteAllowedTmpOnly() async throws {
        guard FileManager.default.fileExists(atPath: SandboxProfile.sandboxExecPath) else {
            return  // environment without sandbox-exec: skip live check
        }
        let ws = tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let paths = SandboxProfile.Paths(workingDir: ws.path)
        let profileURL = ws.appendingPathComponent("test.sb")
        try SandboxProfile.write(to: profileURL, paths: paths)

        let runner = ProcessRunner(timeout: 30)
        let ok = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "echo x > tmp/out.txt && cat tmp/out.txt"],
            environment: [:],
            workingDirectory: ws.path,
            sandbox: .sandbox(profileFileURL: profileURL, paths: paths)
        )
        #expect(ok.succeeded, "stderr: \(ok.stderr)")
        #expect(ok.stdout == "x\n")
        #expect(try String(contentsOf: ws.appendingPathComponent("tmp/out.txt"), encoding: .utf8) == "x\n")

        // Write outside WORKING_TMP must be rejected by Seatbelt.
        let denied = await runner.run(
            executable: "/bin/zsh",
            arguments: ["-c", "echo x > blocked.txt"],
            environment: [:],
            workingDirectory: ws.path,
            sandbox: .sandbox(profileFileURL: profileURL, paths: paths)
        )
        #expect(!denied.succeeded)
        #expect(denied.exitCode != 0 || denied.exitSignal != nil)
    }

    @Test func sandboxBlocksNetwork() async throws {
        guard FileManager.default.fileExists(atPath: SandboxProfile.sandboxExecPath) else { return }
        let ws = tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let paths = SandboxProfile.Paths(workingDir: ws.path)
        let profileURL = ws.appendingPathComponent("test.sb")
        try SandboxProfile.write(to: profileURL, paths: paths)

        let runner = ProcessRunner(timeout: 20)
        let result = await runner.run(
            executable: "/usr/bin/curl",
            arguments: ["--max-time", "5", "-o", "/dev/null", "-s", "https://example.com"],
            environment: [:],
            workingDirectory: ws.path,
            sandbox: .sandbox(profileFileURL: profileURL, paths: paths)
        )
        // DNS is denied outright → curl exits non-zero with exit code 6.
        #expect(!result.succeeded)
        #expect(result.exitCode == 6, "curl exit \(result.exitCode.map(String.init) ?? "?")")
    }

    @Test func sandboxSmokeTestPasses() async {
        guard FileManager.default.fileExists(atPath: SandboxProfile.sandboxExecPath) else { return }
        let ws = tempWorkspace()
        defer { try? FileManager.default.removeItem(at: ws) }
        let outcome = await SandboxProfile.smokeTest(paths: .init(workingDir: ws.path))
        guard case .ok = outcome else {
            Issue.record("smoke failed: \(outcome)")
            return
        }
    }
}
