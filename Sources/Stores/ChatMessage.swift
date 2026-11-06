//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ChatMessage.swift
//

import Foundation

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    /// The model's reasoning/thinking for this turn. Sent back to the server
    /// as `reasoning_content` so reasoning-preserving chat templates (Qwen3)
    /// render it identically, keeping the prompt prefix stable for KV reuse.
    public var reasoning: String?
    public var toolCallId: String?
    public var name: String?
    public var toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoning = "reasoning_content"
        case toolCallId = "tool_call_id"
        case name
        case toolCalls = "tool_calls"
    }

    public init(
        role: String,
        content: String? = nil,
        reasoning: String? = nil,
        toolCallId: String? = nil,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCallId = toolCallId
        self.name = name
        self.toolCalls = toolCalls
    }
}

public struct ToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: FunctionCall

    public init(id: String, type: String = "function", function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct FunctionCall: Codable, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}
