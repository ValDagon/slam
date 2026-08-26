import Foundation
import Testing
@testable import SwiftAgent

@Suite struct TelegramFormatTests {
    @Test func escapeReplacesHtmlMetacharacters() {
        #expect(TelegramFormat.escape("a < b & c > d") == "a &lt; b &amp; c &gt; d")
        #expect(TelegramFormat.plain("x") == "x")
    }

    @Test func shellWrapsTranscriptInPreAndHintsInItalic() {
        let transcript = """
        $ echo "test" > test.txt
        exit: 1
        stdout:
        tmp
        stderr:
        zsh:1: operation not permitted: test.txt
        подсказка: Operation not permitted — sandbox разрешает запись только в /ws/tmp
        """
        let html = TelegramFormat.shell(transcript)
        #expect(html.contains("<pre>"))
        #expect(html.contains("$ echo \"test\" &gt; test.txt"))
        #expect(html.contains("&gt;"))
        #expect(html.contains("<i>подсказка:"))
        #expect(!html.contains("<pre>подсказка:"))
    }

    @Test func confirmationPutsCommandInCode() {
        let html = TelegramFormat.confirmation(command: "rm -rf tmp/x", reason: "деструктивная команда")
        #expect(html.contains("<code>$ rm -rf tmp/x</code>"))
        #expect(html.contains("Причина: деструктивная команда"))
    }

    @Test func preEscapesBody() {
        #expect(TelegramFormat.pre("a < b") == "<pre>a &lt; b</pre>")
    }
}
