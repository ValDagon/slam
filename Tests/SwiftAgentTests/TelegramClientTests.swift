import Foundation
import Testing
@testable import SwiftAgent

/// Client-level scenarios; StubProtocol state is token-keyed, so suites do not
/// interfere under parallel execution.
@Suite struct TelegramClientScenarioTests {
    // Each test owns a unique bot token: StubProtocol keys canned responses by
    // token, so parallel tests can never consume each other's responses.
    @Test func getUpdatesSuccessParsesUpdates() async throws {
        let token = "TOK-PARSE"
        let updatesJSON = Data("""
        [
          {"update_id": 1001,
           "message": {"message_id": 7, "date": 1756118000,
                       "chat": {"id": 555, "type": "private"},
                       "from": {"id": 555, "is_bot": false, "first_name": "Val"},
                       "text": "hello"}},
          {"update_id": 1002}
        ]
        """.utf8)
        StubProtocol.enqueue(token, "getUpdates", .success((200, wrapResult(updatesJSON))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        let updates = try await client.getUpdates(offset: 1000, timeoutSeconds: 30)

        #expect(updates.count == 2)
        #expect(updates[0].updateId == 1001)
        #expect(updates[0].effectiveText == "hello")
        #expect(updates[0].senderId == 555)
        #expect(updates[1].message == nil)

        // Request shape: method, offset and timeout present.
        let url = try #require(StubProtocol.lastRequest(token)?.url)
        #expect(url.absoluteString.contains("/bot\(token)/getUpdates"))
        #expect(url.absoluteString.contains("offset=1000"))
        #expect(url.absoluteString.contains("timeout=30"))
    }

    @Test func conflictMappedToDedicatedError() async {
        let token = "TOK-CONFLICT"
        StubProtocol.enqueue(token, "getUpdates", .success((409, Data(#"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#.utf8))))
        let client = TelegramClient(token: token, session: makeStubbedSession())
        do {
            _ = try await client.getUpdates(offset: nil, timeoutSeconds: 1)
            Issue.record("expected conflict")
        } catch let error as TelegramAPIError {
            guard case .conflict = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func rateLimitCarriesRetryAfter() async {
        let token = "TOK-RATELIMIT-BODY"
        StubProtocol.enqueue(token, "sendMessage", .success((429, Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":17}}"#.utf8))))
        let client = TelegramClient(token: token, session: makeStubbedSession())
        do {
            _ = try await client.sendMessage(chatId: 1, text: "x")
            Issue.record("expected rate limit")
        } catch let error as TelegramAPIError {
            guard case .rateLimit(let retryAfter) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(retryAfter == 17)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func rateLimitFallsBackToRetryAfterHeaderWhenBodyOmitsIt() async {
        let token = "TOK-RATELIMIT-HEADER"
        StubProtocol.enqueue(
            token,
            "sendMessage",
            .success((429, Data(#"{"ok":false,"error_code":429,"description":"Too Many Requests"}"#.utf8))),
            headers: ["Retry-After": "23"]
        )
        let client = TelegramClient(token: token, session: makeStubbedSession())
        do {
            _ = try await client.sendMessage(chatId: 1, text: "x")
            Issue.record("expected rate limit")
        } catch let error as TelegramAPIError {
            guard case .rateLimit(let retryAfter) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(retryAfter == 23)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func transportFailureSurfacesAsTransportError() async {
        let token = "TOK-TRANSPORT"
        StubProtocol.enqueue(token, "getMe", .failure(URLError(.notConnectedToInternet)))
        let client = TelegramClient(token: token, session: makeStubbedSession())
        do {
            _ = try await client.getMe()
            Issue.record("expected transport error")
        } catch let error as TelegramAPIError {
            guard case .transport = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func sendMessageSendsJSONBody() async throws {
        let token = "TOK-SEND"
        let messageJSON = Data("""
        {"message_id": 9, "date": 1756118001, "chat": {"id": 555, "type": "private"},
         "from": {"id": 111, "is_bot": true}, "text": "[echo] hi"}
        """.utf8)
        StubProtocol.enqueue(token, "sendMessage", .success((200, wrapResult(messageJSON))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        let sent = try await client.sendMessage(chatId: 555, text: "[echo] hi")
        #expect(sent.text == "[echo] hi")

        // Body is JSON with chat_id and disable_web_page_preview (formatting-agnostic).
        let body = try #require(StubProtocol.lastBody(token))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["disable_web_page_preview"] as? Bool == true)
        #expect(json["chat_id"] as? Int64 == 555)
        #expect(json["parse_mode"] as? String == "HTML")
        #expect(json["text"] as? String == "[echo] hi")
    }

    @Test func sendMessageEscapesPlainHtmlAndPassesThroughHtmlFlag() async throws {
        let token = "TOK-HTML"
        let messageJSON = Data("""
        {"message_id": 10, "date": 1756118001, "chat": {"id": 555, "type": "private"},
         "from": {"id": 111, "is_bot": true}, "text": "x"}
        """.utf8)
        StubProtocol.enqueue(token, "sendMessage", .success((200, wrapResult(messageJSON))))
        StubProtocol.enqueue(token, "sendMessage", .success((200, wrapResult(messageJSON))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        _ = try await client.sendMessage(chatId: 555, text: "a < b")
        _ = try await client.sendMessage(chatId: 555, text: "<pre>ok</pre>", html: true)

        let bodies = StubProtocol.recordedBodies(token: token, method: "sendMessage")
        #expect(bodies.count == 2)
        let escaped = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(escaped["text"] as? String == "a &lt; b")
        let raw = try #require(JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        #expect(raw["text"] as? String == "<pre>ok</pre>")
    }

    @Test func sendChatActionPostsTyping() async throws {
        let token = "TOK-TYPING"
        StubProtocol.enqueue(token, "sendChatAction", .success((200, Data(#"{"ok":true,"result":true}"#.utf8))))

        let client = TelegramClient(token: token, session: makeStubbedSession())
        let ok = try await client.sendChatAction(chatId: 555)
        #expect(ok == true)

        let body = try #require(StubProtocol.lastBody(token))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["chat_id"] as? Int64 == 555)
        #expect(json["action"] as? String == "typing")
    }

    private func wrapResult(_ rawJSON: Data) -> Data {
        // Build {"ok":true,"result": <raw>} without re-coding through Codable.
        var out = Data(#"{"ok":true,"result":"#.utf8)
        out.append(rawJSON)
        out.append(Data("}".utf8))
        return out
    }
}
