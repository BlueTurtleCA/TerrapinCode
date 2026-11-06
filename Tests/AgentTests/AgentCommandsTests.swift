//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// AgentCommandsTests.swift
//

import Foundation
import Helpers
import Stores
import Testing

@testable import Agent

/// A history of `count` 350-char messages (100 estimated tokens each).
private func bigHistory(count: Int) -> [ChatMessage] {
    (0..<count).map { i in
        ChatMessage(
            role: i.isMultiple(of: 2) ? "user" : "assistant",
            content: String(repeating: "x", count: 350)
        )
    }
}

// MARK: - /compact

@Suite("Agent /compact")
struct CompactCommandTests {
    @Test("/compact with no history reports nothing to compact")
    func compactNoHistory() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        let recorder = Recorder()
        await harness.run(prompt: "/compact", recorder: recorder)

        #expect(recorder.chunks == ["ℹ️ /compact: no conversation to compact yet."])
        #expect(harness.llm.callCount == 0)
    }

    @Test("/compact with a short history reports nothing to compact")
    func compactShortHistory() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        await harness.store.saveHistory(bigHistory(count: 3), for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "/compact", recorder: recorder)

        #expect(recorder.chunks == ["ℹ️ /compact: only 3 messages in the conversation; nothing to compact."])
        #expect(harness.llm.callCount == 0)
    }

    @Test("/compact reports when nothing was dropped")
    func compactNothingDropped() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: []),
            contextWindow: 1000
        )
        // 5 messages × 100 tokens fit the 500-token keep budget exactly.
        await harness.store.saveHistory(bigHistory(count: 5), for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "/compact", recorder: recorder)

        #expect(recorder.chunks.first?.contains("already fits within the keep budget") == true)
        #expect((await harness.store.history(for: harness.sessionId))?.count == 5)
    }

    @Test("/compact compacts and reports structured updates")
    func compactSuccess() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: []),
            contextWindow: 1000
        )
        let history = bigHistory(count: 8)
        await harness.store.saveHistory(history, for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "/compact", supportsCompaction: true, recorder: recorder)

        let expected = ContextManager.compactHistory(history, maxTokens: 1000, force: true)
        #expect(expected.compacted)
        #expect(expected.messagesRemoved == 3)
        #expect(expected.messagesKept == 5)

        let compactions = recorder.updates("compaction_update")
        #expect(compactions.count == 1)
        #expect(compactions[0]["status"] as? String == "completed")
        #expect((compactions[0]["compactionId"] as? String)?.hasPrefix("cmp_") == true)
        let meta = compactions[0]["_meta"] as? [String: Any]
        #expect(meta?["messagesRemoved"] as? Int == expected.messagesRemoved)
        #expect(meta?["messagesKept"] as? Int == expected.messagesKept)
        #expect(meta?["tokensBefore"] as? Int == expected.tokensBefore)
        #expect(meta?["tokensAfter"] as? Int == expected.tokensAfter)

        let usages = recorder.updates("usage_update")
        #expect(usages.count == 1)
        #expect(usages[0]["used"] as? Int == expected.tokensAfter)
        #expect(usages[0]["size"] as? Int == 1000)

        // The compacted history was saved and the LLM was never called.
        let saved = await harness.store.history(for: harness.sessionId) ?? []
        #expect(saved.count == expected.messages.count)
        #expect(harness.llm.callCount == 0)
    }

    @Test("/compact without compaction support reports a plain message")
    func compactFallback() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: []),
            contextWindow: 1000
        )
        await harness.store.saveHistory(bigHistory(count: 8), for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "/compact", supportsCompaction: false, recorder: recorder)

        #expect(recorder.updates("compaction_update").isEmpty)
        #expect(recorder.updates("usage_update").isEmpty)
        let chunk = recorder.chunks.first ?? ""
        #expect(chunk.hasPrefix("ℹ️ Compacted conversation:"))
        #expect(chunk.contains("removed 3 older messages"))
        #expect(chunk.contains("kept the most recent 5 messages"))
    }

    @Test("/compact on the last line of a multi-line prompt compacts")
    func compactMultiLine() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: []),
            contextWindow: 1000
        )
        await harness.store.saveHistory(bigHistory(count: 8), for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "some context\n/compact", supportsCompaction: true, recorder: recorder)

        #expect(recorder.updates("compaction_update").count == 1)
        #expect(harness.llm.callCount == 0)
    }

    @Test("/compact with a trailing argument is not the command")
    func compactNotACommand() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "/compact please", recorder: recorder)

        #expect(harness.llm.callCount == 1)
        #expect(recorder.chunks.joined() == "ok")
    }

    // MARK: - Automatic Compaction

    @Test("an oversized history is compacted before the LLM call")
    func automaticCompaction() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            contextWindow: 1000
        )
        // 10 × 100 tokens + the new prompt exceeds the 900-token limit.
        await harness.store.saveHistory(bigHistory(count: 10), for: harness.sessionId)
        let recorder = Recorder()
        await harness.run(prompt: "new prompt", supportsCompaction: true, recorder: recorder)

        #expect(recorder.updates("compaction_update").count == 1)
        #expect(recorder.updates("usage_update").count == 1)

        // The model sees the compaction notice pair, not the old history.
        let firstCall = harness.llm.calls[0].messages
        #expect(firstCall[0].role == "user")
        #expect(firstCall[0].content?.contains("compacted") == true)
        #expect(firstCall[1].role == "assistant")
        #expect(firstCall.last?.content == "new prompt")
    }
}

// MARK: - /debug

@Suite("Agent /debug")
struct DebugCommandTests {
    @Test("/debug replays JSON objects from a file")
    func debugReplay() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        harness.temp.writeFile(
            "replay.json",
            contents: """
            {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"[SessionId]","update":{"sessionUpdate":"agent_message","content":{"type":"text","text":"hello [UUID]"}}}}
            ---
            {"jsonrpc":"2.0","id":1,"result":{}}
            """
        )
        let recorder = Recorder()
        await harness.run(prompt: "/debug replay.json", recorder: recorder)

        #expect(recorder.jsons.count == 2)
        let params = recorder.jsons[0]["params"] as? [String: Any]
        #expect(params?["sessionId"] as? String == harness.sessionId)
        let update = params?["update"] as? [String: Any]
        let content = update?["content"] as? [String: Any]
        let text = content?["text"] as? String ?? ""
        #expect(text.hasPrefix("hello "))
        #expect(text.count == "hello ".count + 36) // [UUID] became a UUID

        #expect(recorder.chunks.last?.contains("sent 2 of 2 JSON object(s)") == true)
        #expect(harness.llm.callCount == 0)
        #expect(await harness.store.history(for: harness.sessionId) == nil)
    }

    @Test("/debug accepts absolute paths")
    func debugAbsolutePath() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        let file = harness.temp.writeFile("abs.json", contents: #"{"a":1}"#)
        let recorder = Recorder()
        await harness.run(prompt: "/debug \(file.path)", recorder: recorder)

        #expect(recorder.jsons.count == 1)
    }

    @Test("/debug with a missing file warns")
    func debugMissingFile() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        let recorder = Recorder()
        await harness.run(prompt: "/debug missing.json", recorder: recorder)

        #expect(recorder.chunks == ["⚠️ /debug: could not read file: \(harness.cwd)/missing.json"])
        #expect(recorder.jsons.isEmpty)
    }

    @Test("/debug skips invalid JSON objects")
    func debugInvalidJSON() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        harness.temp.writeFile(
            "mixed.json",
            contents: """
            {"a":1}
            ---
            not json
            ---
            {"b":2}
            """
        )
        let recorder = Recorder()
        await harness.run(prompt: "/debug mixed.json", recorder: recorder)

        #expect(recorder.jsons.count == 2)
        #expect(recorder.chunks.contains("⚠️ /debug: skipping invalid JSON at object #2"))
        #expect(recorder.chunks.last?.contains("sent 2 of 3 JSON object(s)") == true)
    }

    @Test("/debug with an empty file warns")
    func debugEmptyFile() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: []))
        harness.temp.writeFile("empty.json", contents: "")
        let recorder = Recorder()
        await harness.run(prompt: "/debug empty.json", recorder: recorder)

        #expect(recorder.chunks.contains { $0.hasPrefix("⚠️ /debug: no JSON objects found in") })
        #expect(recorder.jsons.isEmpty)
    }
}
