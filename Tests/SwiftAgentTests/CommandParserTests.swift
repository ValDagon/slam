import Testing
@testable import SwiftAgent

struct CommandParserTests {
    @Test func plainTextPassesThroughVerbatim() {
        #expect(CommandParser.Parsed.from("привет мир") == .plain(text: "привет мир"))
        // Text is trimmed before the "/" prefix check, so a spaced-out unknown
        // command parses as unknownCommand of the trimmed string.
        #expect(CommandParser.Parsed.from("  /not a command") == .unknownCommand("/not a command"))
    }

    @Test func basicCommands() {
        #expect(CommandParser.Parsed.from("/start") == .start)
        #expect(CommandParser.Parsed.from("/help") == .help)
        #expect(CommandParser.Parsed.from("  /status  ") == .status)
        #expect(CommandParser.Parsed.from("/model qwen2.5:7b") == .model(name: "qwen2.5:7b"))
        #expect(CommandParser.Parsed.from("/model") == .unknownCommand("/model"))
    }

    @Test func allowDenyWithIds() {
        #expect(CommandParser.Parsed.from("/allow 123456789") == .allow(id: 123456789))
        #expect(CommandParser.Parsed.from("/deny 42") == .deny(id: 42))
        // Missing or non-numeric id is an unknown command, not a crash.
        #expect(CommandParser.Parsed.from("/allow") == .unknownCommand("/allow"))
        #expect(CommandParser.Parsed.from("/allow abc") == .unknownCommand("/allow abc"))
    }

    @Test func botSuffixStrippedInGroups() {
        #expect(CommandParser.Parsed.from("/status@my_agent_bot") == .status)
    }
}
