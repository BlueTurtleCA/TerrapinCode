//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ToolDefinition.swift
//

import Foundation

// MARK: - OpenAI / AI Server Compatible Tool Models

public struct ToolDefinition: Codable, Sendable {
    public let type: String
    public let function: FunctionDefinition

    public init(type: String = "function", function: FunctionDefinition) {
        self.type = type
        self.function = function
    }
}

public struct FunctionDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: AnySendable] // Dynamic JSON schema from MCP

    public init(name: String, description: String, parameters: [String: AnySendable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// Lightweight Sendable wrapper for untyped JSON schemas
public struct AnySendable: Codable, Sendable {
    public let value: Sendable

    public init(_ value: Sendable) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnySendable].self) {
            value = dict
        } else if let array = try? container.decode([AnySendable].self) {
            value = array
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else {
            value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let stringArray = value as? [String] {
            try container.encode(stringArray)
        } else if let array = value as? [AnySendable] {
            try container.encode(array)
        } else if let dict = value as? [String: AnySendable] {
            try container.encode(dict)
        } else {
            try container.encode(String(describing: value))
        }
    }
}
