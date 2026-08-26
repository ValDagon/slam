import Foundation
import Testing
@testable import SwiftAgent

@Suite struct CommandSafetyTests {
    // MARK: - Fence extraction

    @Test func extractsSimpleRunBlock() {
        let text = "Вот результат:\n```run\nls -la\n```"
        #expect(CommandSafety.extractRunCommand(from: text) == "ls -la")
    }

    @Test func extractionTrimsWhitespace() {
        let text = "```run\n   echo hi\n```"
        #expect(CommandSafety.extractRunCommand(from: text) == "echo hi")
    }

    @Test func unterminatedBlockIsRejected() {
        #expect(CommandSafety.extractRunCommand(from: "```run\necho hi") == nil)
    }

    @Test func emptyBlockIsRejected() {
        #expect(CommandSafety.extractRunCommand(from: "```run\n```") == nil)
    }

    @Test func noBlockMeansNoCommand() {
        #expect(CommandSafety.extractRunCommand(from: "обычный ответ без блоков") == nil)
        #expect(CommandSafety.extractRunCommand(from: "```\nplain code\n```") == nil)
    }

    @Test func firstBlockWins() {
        let text = "```run\none\n```\nтекст\n```run\ntwo\n```"
        #expect(CommandSafety.extractRunCommand(from: text) == "one")
    }

    @Test func strippingRemovesBlocks() {
        let text = "до ```run\nsecret\n``` после"
        let stripped = CommandSafety.strippingRunBlocks(from: text)
        #expect(!stripped.contains("secret"))
        #expect(stripped.contains("до"))
        #expect(stripped.contains("после"))
    }

    // MARK: - Destructive classification

    @Test func rmRequiresConfirmation() {
        let plan = CommandSafety.plan(command: "rm -rf /tmp/x")
        #expect(plan.requiresConfirmation)
        #expect(plan.reason != nil)
    }

    @Test func harmlessCommandsPassThrough() {
        for cmd in ["ls -la", "cat file.txt", "echo hello", "grep -r pattern ."] {
            #expect(!CommandSafety.plan(command: cmd).requiresConfirmation, "false positive on: \(cmd)")
        }
    }

    @Test func substringDoesNotTrigger() {
        // "формируем" contains no standalone rm; word boundary must hold.
        #expect(!CommandSafety.plan(command: "echo reforming").requiresConfirmation)
        #expect(CommandSafety.plan(command: "rm -rf x").requiresConfirmation)
    }

    @Test func extraPatternsAreHonored() {
        let plan = CommandSafety.plan(command: "make deploy", extraPatterns: [#"\bmake\b"#])
        #expect(plan.requiresConfirmation)
    }

    @Test func caseInsensitive() {
        #expect(CommandSafety.plan(command: "RM -RF x").requiresConfirmation)
    }

    // MARK: - Sandbox scope advisory

    @Test func homeScanWarns() {
        let ws = "/Users/demo/.local/share/slam/workspace"
        let warn = CommandSafety.sandboxScopeWarning(
            command: "find ~ -type f -exec du -h {} + | sort -rh | head -n 1",
            workingDir: ws
        )
        #expect(warn != nil)
        #expect(warn!.contains("workspace"))
    }

    @Test func workspaceFindDoesNotWarn() {
        let ws = "/Users/demo/.local/share/slam/workspace"
        #expect(CommandSafety.sandboxScopeWarning(command: "find . -type f | head", workingDir: ws) == nil)
        #expect(CommandSafety.sandboxScopeWarning(command: "du -sh .", workingDir: ws) == nil)
    }

    // MARK: - Write-attempt detection (FR-22 hint accuracy)

    @Test func redirectionLooksLikeWrite() {
        #expect(CommandSafety.looksLikeWriteAttempt(#"echo "test" > test.txt"#))
        #expect(CommandSafety.looksLikeWriteAttempt("echo hi >> log.txt"))
        #expect(CommandSafety.looksLikeWriteAttempt("touch test.txt"))
        #expect(CommandSafety.looksLikeWriteAttempt("mkdir sub"))
        #expect(CommandSafety.looksLikeWriteAttempt("cp a.txt b.txt"))
        #expect(CommandSafety.looksLikeWriteAttempt("mv a.txt b.txt"))
        #expect(CommandSafety.looksLikeWriteAttempt("dd if=/dev/zero of=out.bin bs=1 count=1"))
        #expect(CommandSafety.looksLikeWriteAttempt("sed -i '' 's/a/b/' file.txt"))
    }

    @Test func readOnlyCommandsDoNotLookLikeWrite() {
        #expect(!CommandSafety.looksLikeWriteAttempt("ls -la"))
        #expect(!CommandSafety.looksLikeWriteAttempt("cat test.txt"))
        #expect(!CommandSafety.looksLikeWriteAttempt("find . -type f"))
        #expect(!CommandSafety.looksLikeWriteAttempt("echo hi 2>&1"))
    }
}
