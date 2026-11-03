//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ContextResolver.swift
//

import Foundation
import Stores

public struct ContextManager {

    /// Estimates token count for a message list (approx. 1 token = 3.5 characters)
    static func estimateTokenCount(_ history: [ChatMessage]) -> Int {
        var totalChars = 0
        for msg in history {
            totalChars += msg.content?.count ?? 0
            totalChars += msg.reasoning?.count ?? 0
            if let toolCalls = msg.toolCalls {
                for call in toolCalls {
                    totalChars +=
                        call.function.name.count + call.function.arguments.count
                }
            }
        }
        return Int(Double(totalChars) / 3.5)
    }

    /// The outcome of a history compaction: the compacted message list plus
    /// stats describing what was dropped, for reporting to the client.
    public struct CompactionResult: Sendable {
        /// The history to use going forward (identical to the input when
        /// `compacted` is false).
        public let messages: [ChatMessage]
        /// Whether any original messages were dropped.
        public let compacted: Bool
        /// Number of original messages that were removed.
        public let messagesRemoved: Int
        /// Number of recent original messages kept in the window.
        public let messagesKept: Int
        /// Estimated token count of the history before compaction.
        public let tokensBefore: Int
        /// Estimated token count of the history after compaction.
        public let tokensAfter: Int
    }

    /// Safely truncates middle messages when token limit is approached
    public static func compactHistory(
        _ history: [ChatMessage],
        maxTokens: Int = 16384,  // Set to your model's context size (e.g. 8192, 16384, 32768)
        targetBudgetRatio: Double = 0.90,  // Compact when usage exceeds 90% of max context
        force: Bool = false  // Bypass the token threshold (manual /compact)
    ) -> CompactionResult {
        let currentTokens = estimateTokenCount(history)
        let tokenLimit = Int(Double(maxTokens) * targetBudgetRatio)

        // Return untouched if within context budget. A forced compaction
        // bypasses the token threshold but still needs more than four
        // messages, since the recent window would keep everything else.
        guard history.count > 4, force || currentTokens > tokenLimit else {
            return CompactionResult(
                messages: history,
                compacted: false,
                messagesRemoved: 0,
                messagesKept: history.count,
                tokensBefore: currentTokens,
                tokensAfter: currentTokens
            )
        }

        let systemMessage = history.first { $0.role == "system" }
        var compacted: [ChatMessage] = []

        if let systemMessage {
            compacted.append(systemMessage)
        }

        // Add a compaction notice marker
        compacted.append(
            ChatMessage(
                role: "user",
                content:
                    "System Note: Older conversation turns were compacted to stay within the context window limit."
            )
        )
        compacted.append(
            ChatMessage(
                role: "assistant",
                content:
                    "Understood. I will continue focusing on your latest commands using the existing workspace state."
            )
        )

        // Keep the most recent messages that fit within a token budget, so a
        // single huge tool result can't blow the window and small turns keep
        // more context than a fixed message count would allow.
        let keepBudget = Int(Double(maxTokens) * 0.50)
        var recentMessages: [ChatMessage] = []
        var usedTokens = 0
        for message in history.reversed() {
            let messageTokens = estimateTokenCount([message])
            if !recentMessages.isEmpty, usedTokens + messageTokens > keepBudget {
                break
            }
            recentMessages.insert(message, at: 0)
            usedTokens += messageTokens
        }

        // Ensure we don't start recent history with an orphaned tool response
        while let first = recentMessages.first, first.role == "tool" {
            recentMessages.removeFirst()
        }

        compacted.append(contentsOf: recentMessages)

        // Count the original messages that survived: the recent window, plus
        // the system message when it was prepended rather than kept in the
        // window (a mid-history system message can be in both).
        var retained = recentMessages.count
        if systemMessage != nil,
            !recentMessages.contains(where: { $0.role == "system" })
        {
            retained += 1
        }

        return CompactionResult(
            messages: compacted,
            compacted: true,
            messagesRemoved: history.count - retained,
            messagesKept: recentMessages.count,
            tokensBefore: currentTokens,
            tokensAfter: estimateTokenCount(compacted)
        )
    }

    /// Queries the AI server's endpoints to retrieve the loaded model's context window
    public static func resolveContextWindow(
        _ endpoint: String
    ) async -> Int {
        await resolveContextWindow(endpoint) { url in
            let (data, _) = try await URLSession.shared.data(from: url)
            return data
        }
    }

    /// Testable variant of ``resolveContextWindow(_:)`` with an injectable fetcher.
    static func resolveContextWindow(
        _ endpoint: String,
        fetch: @Sendable (URL) async throws -> Data
    ) async -> Int {
        let candidateURLs = [
            "\(endpoint)/api/v1/models",
            "\(endpoint)/v1/models",
        ].compactMap { URL(string: $0) }

        for url in candidateURLs {
            guard let data = try? await fetch(url),
                let json = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let models = json["data"] as? [[String: Any]],
                let activeModel = models.first(where: {
                    ($0["state"] as? String) == "loaded"
                }) ?? models.first
            else {
                continue
            }

            // llama.cpp reports the context length inside a "meta" object, and
            // the exact key varies by version:
            //   new: data[0].meta.n_ctx
            //   old: data[0].meta.model_info.context_length
            // Check "meta" first so we don't silently fall back to 16384 (which
            // would make compaction fire every turn and destroy KV prefix reuse).
            if let meta = activeModel["meta"] as? [String: Any] {
                if let ctxLen = meta["n_ctx"] as? Int {
                    return ctxLen
                }
                if let modelInfo = meta["model_info"] as? [String: Any],
                    let ctxLen = modelInfo["context_length"] as? Int
                {
                    return ctxLen
                }
                if let ctxLen = meta["context_length"] as? Int {
                    return ctxLen
                }
            }

            // 1. Check direct server property
            if let maxCtx = activeModel["max_context_length"] as? Int {
                return maxCtx
            }

            // 2. Some servers expose model_info at the top level
            if let modelInfo = activeModel["model_info"] as? [String: Any],
                let ctxLen = modelInfo["context_length"] as? Int
            {
                return ctxLen
            }

            // 3. Check active instance config (v1 REST API)
            if let instances = activeModel["loaded_instances"]
                as? [[String: Any]],
                let config = instances.first?["config"] as? [String: Any],
                let ctxLen = config["context_length"] as? Int
            {
                return ctxLen
            }

            // 4. Check standard fallback property
            if let ctxLen = activeModel["context_length"] as? Int {
                return ctxLen
            }
        }

        // Conservative fallback if metadata is unavailable
        return 16384
    }
}
