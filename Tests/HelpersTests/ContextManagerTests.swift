//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ContextManagerTests.swift
//

import Foundation
import Testing
import Stores

@testable import Helpers

// MARK: - Shared helpers

/// Builds a message whose content is exactly `chars` characters long.
/// At the 3.5 chars/token rate: 350 chars = 100 tokens, 700 = 200,
/// 1050 = 300, 1750 = 500, 3500 = 1000.
private func message(_ role: String, chars: Int) -> ChatMessage {
    ChatMessage(role: role, content: String(repeating: "x", count: chars))
}

/// Compares two message lists field by field (ChatMessage is not Equatable).
private func expectSameMessages(
    _ lhs: [ChatMessage],
    _ rhs: [ChatMessage]
) {
    #expect(lhs.count == rhs.count)
    for (index, (a, b)) in zip(lhs, rhs).enumerated() {
        #expect(a.role == b.role, "role mismatch at index \(index)")
        #expect(a.content == b.content, "content mismatch at index \(index)")
        #expect(a.reasoning == b.reasoning, "reasoning mismatch at index \(index)")
        #expect(a.toolCallId == b.toolCallId, "toolCallId mismatch at index \(index)")
        #expect(a.name == b.name, "name mismatch at index \(index)")
        #expect(
            a.toolCalls?.count == b.toolCalls?.count,
            "toolCalls count mismatch at index \(index)"
        )
    }
}

// MARK: - estimateTokenCount

@Suite("estimateTokenCount")
struct EstimateTokenCountTests {
    @Test func emptyHistoryIsZero() {
        #expect(ContextManager.estimateTokenCount([]) == 0)
    }

    @Test func contentIsCountedAtThreePointFiveCharsPerToken() {
        let msg = ChatMessage(role: "user", content: String(repeating: "a", count: 35))
        #expect(ContextManager.estimateTokenCount([msg]) == 10)
    }

    @Test func reasoningIsCounted() {
        let msg = ChatMessage(
            role: "assistant",
            content: String(repeating: "a", count: 35),
            reasoning: String(repeating: "b", count: 35)
        )
        #expect(ContextManager.estimateTokenCount([msg]) == 20)
    }

    @Test func toolCallNamesAndArgumentsAreCounted() {
        let call = ToolCall(
            id: "call_1",
            function: FunctionCall(
                name: String(repeating: "n", count: 10),
                arguments: String(repeating: "a", count: 25)
            )
        )
        let msg = ChatMessage(role: "assistant", toolCalls: [call])
        #expect(ContextManager.estimateTokenCount([msg]) == 10)
    }

    @Test func nilFieldsContributeNothing() {
        let msg = ChatMessage(role: "user")
        #expect(ContextManager.estimateTokenCount([msg]) == 0)
    }

    @Test func multipleMessagesAreSummed() {
        let a = ChatMessage(role: "user", content: String(repeating: "a", count: 35))
        let b = ChatMessage(role: "assistant", content: String(repeating: "b", count: 70))
        #expect(ContextManager.estimateTokenCount([a, b]) == 30)
    }
}

// MARK: - compactHistory

@Suite("compactHistory")
struct CompactHistoryTests {
    @Test func emptyHistoryStaysEmpty() {
        #expect(ContextManager.compactHistory([], maxTokens: 1000).messages.isEmpty)
    }

    @Test func withinBudgetReturnsHistoryUnchanged() {
        let history = [
            message("system", chars: 350),
            message("user", chars: 350),
            message("assistant", chars: 350),
            message("user", chars: 350),
            message("assistant", chars: 350),
        ]
        // 500 tokens total, under the 900-token limit (1000 × 0.90)
        let result = ContextManager.compactHistory(history, maxTokens: 1000)
        #expect(!result.compacted)
        #expect(result.messagesRemoved == 0)
        #expect(result.tokensBefore == result.tokensAfter)
        expectSameMessages(result.messages, history)
    }

    @Test func fourOrFewerMessagesAreNeverCompacted() {
        let history = (0..<4).map { _ in message("user", chars: 3500) }
        // 4000 tokens, far over the limit, but the count guard (<= 4) wins
        let result = ContextManager.compactHistory(history, maxTokens: 1000)
        #expect(!result.compacted)
        expectSameMessages(result.messages, history)
    }

    @Test func forceCompactsBelowThreshold() {
        let history = (0..<8).map { i in
            message(i.isMultiple(of: 2) ? "user" : "assistant", chars: 350) // 100 tokens each
        }
        // 800 tokens, under the 900 limit, but force bypasses the threshold
        let result = ContextManager.compactHistory(history, maxTokens: 1000, force: true)

        #expect(result.compacted)
        #expect(result.tokensBefore == 800)
        // keepBudget is 500 tokens, so the five most recent messages fit
        #expect(result.messagesKept == 5)
        #expect(result.messagesRemoved == 3)
    }

    @Test func forceStillRequiresMoreThanFourMessages() {
        let history = (0..<4).map { _ in message("user", chars: 3500) }
        let result = ContextManager.compactHistory(history, maxTokens: 1000, force: true)
        #expect(!result.compacted)
        expectSameMessages(result.messages, history)
    }

    @Test func compactionKeepsSystemMessageAndNoticePair() {
        let history = [
            message("system", chars: 350),     // 100 tokens
            message("user", chars: 1750),      // 500
            message("assistant", chars: 1750), // 500
            message("user", chars: 1750),      // 500
            message("assistant", chars: 1750), // 500
            message("user", chars: 1750),      // 500
        ]
        // 2600 tokens > 900 limit, 6 messages > 4
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 4)
        #expect(result.messages[0].role == "system")
        #expect(result.messages[0].content == history[0].content)
        #expect(result.messages[1].role == "user")
        #expect(
            result.messages[1].content
                == "System Note: Older conversation turns were compacted to stay within the context window limit."
        )
        #expect(result.messages[2].role == "assistant")
        #expect(
            result.messages[2].content
                == "Understood. I will continue focusing on your latest commands using the existing workspace state."
        )
        // keepBudget is 500 tokens, so only the final 500-token message fits
        #expect(result.messages[3].role == "user")
        #expect(result.messages[3].content == history[5].content)
        // Stats: the 4 middle messages were dropped; the system message and
        // the final message survived.
        #expect(result.messagesRemoved == 4)
        #expect(result.messagesKept == 1)
        #expect(result.tokensBefore == 2600)
        #expect(result.tokensAfter < result.tokensBefore)
    }

    @Test func compactionWithoutSystemMessageStartsWithNotice() {
        let history = (0..<5).map { i in
            message(i.isMultiple(of: 2) ? "user" : "assistant", chars: 1750)
        }
        // 2500 tokens > 900 limit
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 3)
        #expect(result.messages[0].role == "user")
        #expect(result.messages[0].content?.contains("compacted") == true)
        #expect(result.messages[1].role == "assistant")
        #expect(result.messages[2].content == history[4].content)
        #expect(result.messagesRemoved == 4)
        #expect(result.messagesKept == 1)
    }

    @Test func multipleRecentMessagesAreKeptWhileBudgetAllows() {
        let history = [
            message("system", chars: 700),     // 200 tokens
            message("user", chars: 700),       // 200
            message("assistant", chars: 700),  // 200
            message("user", chars: 700),       // 200
            message("assistant", chars: 700),  // 200
            message("user", chars: 700),       // 200
        ]
        // 1200 tokens > 900 limit; keepBudget is 500
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 5)
        #expect(result.messages[3].content == history[4].content)
        #expect(result.messages[4].content == history[5].content)
        #expect(result.messagesRemoved == 3)
        #expect(result.messagesKept == 2)
    }

    @Test func oversizedMostRecentMessageIsAlwaysKept() {
        let history = [
            message("system", chars: 350),      // 100 tokens
            message("user", chars: 1750),       // 500
            message("assistant", chars: 1750),  // 500
            message("user", chars: 1750),       // 500
            message("assistant", chars: 3500),  // 1000 — alone exceeds the 500 keepBudget
        ]
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 4)
        #expect(result.messages[3].role == "assistant")
        #expect(result.messages[3].content?.count == 3500)
        #expect(result.messagesRemoved == 3)
        #expect(result.messagesKept == 1)
    }

    @Test func orphanedLeadingToolMessageIsStripped() {
        let history = [
            message("system", chars: 700),      // 200 tokens
            message("user", chars: 700),        // 200
            message("assistant", chars: 700),   // 200
            message("tool", chars: 700),        // 200
            message("tool", chars: 700),        // 200
            message("assistant", chars: 700),   // 200
        ]
        // keepBudget 500 keeps [tool, assistant]; the leading tool is stripped
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 4)
        #expect(result.messages[3].role == "assistant")
        #expect(result.messages[3].content == history[5].content)
        #expect(result.messagesRemoved == 4)
        #expect(result.messagesKept == 1)
    }

    @Test func multipleOrphanedToolMessagesAreStripped() {
        let history = [
            message("system", chars: 1050),     // 300 tokens
            message("user", chars: 1050),       // 300
            message("assistant", chars: 1050),  // 300
            message("tool", chars: 350),        // 100
            message("tool", chars: 350),        // 100
            message("assistant", chars: 350),   // 100
        ]
        // keepBudget 500 keeps [tool, tool, assistant]; both tools are stripped
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 4)
        #expect(result.messages[3].role == "assistant")
        #expect(result.messages[3].content == history[5].content)
        #expect(result.messagesRemoved == 4)
        #expect(result.messagesKept == 1)
    }

    @Test func midHistorySystemMessageIsDuplicated() {
        // Documented edge case: a system message that is not at index 0 is both
        // prepended and kept in the recent window. With a leading system message
        // (the normal case) this cannot happen, because reaching index 0 within
        // the keep budget would mean the history is under the compaction limit.
        let history = [
            message("user", chars: 700),        // 200 tokens
            message("assistant", chars: 700),   // 200
            message("user", chars: 700),        // 200
            message("system", chars: 700),      // 200
            message("assistant", chars: 700),   // 200
        ]
        let result = ContextManager.compactHistory(history, maxTokens: 1000)

        #expect(result.compacted)
        #expect(result.messages.count == 5)
        #expect(result.messages[0].role == "system")
        #expect(result.messages[3].role == "system")
        // The system message is in the recent window, so it is not counted
        // twice: the first three messages were dropped.
        #expect(result.messagesRemoved == 3)
        #expect(result.messagesKept == 2)
    }
}

// MARK: - resolveContextWindow

@Suite("resolveContextWindow")
struct ResolveContextWindowTests {
    private let endpoint = "http://localhost:8080"

    private func modelsResponse(_ models: [[String: Any]]) -> Data {
        let object: [String: Any] = ["data": models]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// Stub fetcher: `apiV1` answers `/api/v1/models`, `v1` answers `/v1/models`;
    /// a `nil` payload makes that request fail.
    private func fetchStub(
        apiV1: Data?,
        v1: Data?
    ) -> @Sendable (URL) async throws -> Data {
        { url in
            if url.absoluteString.hasSuffix("/api/v1/models") {
                guard let apiV1 else { throw URLError(.cannotConnectToHost) }
                return apiV1
            }
            if url.absoluteString.hasSuffix("/v1/models") {
                guard let v1 else { throw URLError(.cannotConnectToHost) }
                return v1
            }
            throw URLError(.badURL)
        }
    }

    @Test func llamaCppNewFormatMetaNctx() async {
        let response = modelsResponse([
            ["id": "model", "state": "loaded", "meta": ["n_ctx": 32768]],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 32768)
    }

    @Test func llamaCppOldFormatMetaModelInfo() async {
        let response = modelsResponse([
            ["id": "model", "meta": ["model_info": ["context_length": 8192]]],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 8192)
    }

    @Test func metaContextLength() async {
        let response = modelsResponse([
            ["id": "model", "meta": ["context_length": 4096]],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 4096)
    }

    @Test func topLevelMaxContextLength() async {
        let response = modelsResponse([
            ["id": "model", "max_context_length": 100000],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 100000)
    }

    @Test func topLevelModelInfo() async {
        let response = modelsResponse([
            ["id": "model", "model_info": ["context_length": 20000]],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 20000)
    }

    @Test func loadedInstancesConfig() async {
        let response = modelsResponse([
            ["id": "model", "loaded_instances": [["config": ["context_length": 12288]]]],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 12288)
    }

    @Test func topLevelContextLength() async {
        let response = modelsResponse([
            ["id": "model", "context_length": 5000],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 5000)
    }

    @Test func prefersLoadedModelOverFirst() async {
        let response = modelsResponse([
            ["id": "first", "context_length": 1000],
            ["id": "second", "state": "loaded", "context_length": 2000],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 2000)
    }

    @Test func fallsBackToSecondURLWhenFirstFails() async {
        let response = modelsResponse([
            ["id": "model", "context_length": 7777],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: nil, v1: response)
        )
        #expect(result == 7777)
    }

    @Test func fallsBackToDefaultWhenBothURLsFail() async {
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: nil, v1: nil)
        )
        #expect(result == 16384)
    }

    @Test func fallsBackToDefaultOnMalformedJSON() async {
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: Data("not json".utf8), v1: nil)
        )
        #expect(result == 16384)
    }

    @Test func fallsBackToDefaultWhenModelHasNoContextInfo() async {
        let response = modelsResponse([
            ["id": "model", "state": "loaded"],
        ])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 16384)
    }

    @Test func fallsBackToDefaultWhenModelsArrayIsEmpty() async {
        let response = modelsResponse([])
        let result = await ContextManager.resolveContextWindow(
            endpoint,
            fetch: fetchStub(apiV1: response, v1: nil)
        )
        #expect(result == 16384)
    }
}
