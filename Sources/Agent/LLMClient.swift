//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// LLMClient.swift
//

import Foundation
import Stores

/// A single completed turn from the model: text content, reasoning, tool
/// calls, or any combination.
public struct LLMResponse: Sendable {
    public let content: String?
    public let reasoning: String?
    public let toolCalls: [ToolCall]

    public init(content: String?, reasoning: String? = nil, toolCalls: [ToolCall] = []) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
    }
}

public enum LLMError: Error {
    case httpStatus(Int, body: String)
    case badResponse
    case streamInterrupted

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "AI server returned HTTP \(code): \(body)"
        case .badResponse:
            return "Failed to parse response from AI server."
        case .streamInterrupted:
            return "Connection to AI server dropped mid-response."
        }
    }
}

/// Abstraction over a chat-completions backend (mlx server, llama.cpp, LM Studio, ...).
/// Implementations stream the response: `onContent` fires for answer text,
/// `onThought` fires for reasoning/thinking text, and the returned
/// `LLMResponse` is the fully assembled turn.
///
/// `slotId` pins the request to a server-side context slot (llama.cpp's
/// `slot_id`). Servers that keep a per-slot KV cache (llama.cpp) reuse the
/// cached context when the new prompt extends the previous one on the same
/// slot, so only the delta is processed. Servers that don't know the field
/// ignore it.
public protocol LLMClient: Sendable {
    func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        slotId: Int?,
        onContent: @escaping @Sendable (String) -> Void,
        onThought: @escaping @Sendable (String) -> Void
    ) async throws -> LLMResponse
}
