//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// LLMClientTests.swift
//

import Foundation
import Testing

@testable import Agent

// MARK: - LLMError

@Suite("LLMError")
struct LLMErrorTests {
    @Test("httpStatus includes the code and body")
    func httpStatusDescription() {
        let error = LLMError.httpStatus(503, body: "boom")
        #expect(error.errorDescription == "AI server returned HTTP 503: boom")
    }

    @Test("badResponse")
    func badResponseDescription() {
        #expect(LLMError.badResponse.errorDescription == "Failed to parse response from AI server.")
    }

    @Test("streamInterrupted")
    func streamInterruptedDescription() {
        #expect(LLMError.streamInterrupted.errorDescription == "Connection to AI server dropped mid-response.")
    }
}

// MARK: - LLMResponse

@Suite("LLMResponse")
struct LLMResponseTests {
    @Test("defaults leave reasoning nil and tool calls empty")
    func defaults() {
        let response = LLMResponse(content: "hi")
        #expect(response.content == "hi")
        #expect(response.reasoning == nil)
        #expect(response.toolCalls.isEmpty)
    }
}
