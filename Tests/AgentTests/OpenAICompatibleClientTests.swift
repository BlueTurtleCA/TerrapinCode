//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// OpenAICompatibleClientTests.swift
//

import Foundation
import Stores
import Testing

@testable import Agent

/// The endpoint every stubbed request is sent to.
private let endpoint = URL(string: "http://stub.local/v1/chat/completions")!

/// Builds a client wired to the stub session.
private func makeClient(model: String = "test-model") -> OpenAICompatibleClient {
    OpenAICompatibleClient(endpoint: endpoint, model: model, session: makeStubSession())
}

/// A minimal tool definition for request-body assertions.
private let testTool = ToolDefinition(
    function: FunctionDefinition(
        name: "run_command",
        description: "Runs a command",
        parameters: [:]
    )
)

/// Wraps JSON chunk payloads in SSE `data:` lines, ending with [DONE].
private func sse(_ payloads: [String]) -> String {
    (payloads.map { "data: \($0)" } + ["data: [DONE]"]).joined(separator: "\n")
}

/// Decodes the captured request body at `index`.
private func decodedBody(_ index: Int) throws -> [String: Any] {
    let data = StubURLProtocol.capturedBodies[index]
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

/// The one message every test sends.
private let userMessage = ChatMessage(role: "user", content: "hi")

// The stub's state is process-global, so the suite runs serially.
@Suite(.serialized)
struct OpenAICompatibleClientTests {
    // MARK: - Request Construction

    @Test("request is a POST with the OpenAI-compatible body")
    func requestBody() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#]), url: endpoint)

        _ = try await makeClient().complete(
            messages: [userMessage],
            tools: [testTool],
            slotId: 3,
            onContent: { _ in },
            onThought: { _ in }
        )

        let request = StubURLProtocol.capturedRequests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try decodedBody(0)
        #expect(body["model"] as? String == "test-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["slot_id"] as? Int == 3)

        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?.first?["role"] as? String == "user")
        #expect(messages?.first?["content"] as? String == "hi")

        let tools = body["tools"] as? [[String: Any]]
        #expect(tools?.first?["type"] as? String == "function")
        let function = tools?.first?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "run_command")
    }

    @Test("slot_id is omitted when slotId is nil")
    func slotIdOmittedWhenNil() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(sse([#"{"choices":[{"delta":{"content":"ok"}}]}"#]), url: endpoint)

        _ = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: { _ in },
            onThought: { _ in }
        )

        let body = try decodedBody(0)
        #expect(body["slot_id"] == nil)
    }

    // MARK: - SSE Parsing

    @Test("content deltas are accumulated and streamed in order")
    func contentDeltas() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([
                #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
                #"{"choices":[{"delta":{"content":"lo"}}]}"#,
            ]),
            url: endpoint
        )

        let recorder = Recorder()
        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: recorder.chunk,
            onThought: recorder.thought
        )

        #expect(response.content == "Hello")
        #expect(response.reasoning == nil)
        #expect(response.toolCalls.isEmpty)
        #expect(recorder.chunks == ["Hel", "lo"])
    }

    @Test("reasoning_content and reasoning keys both stream thoughts")
    func reasoningKeys() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([
                #"{"choices":[{"delta":{"reasoning_content":"thinking "}}]}"#,
                #"{"choices":[{"delta":{"reasoning":"more"}}]}"#,
                #"{"choices":[{"delta":{"content":"done"}}]}"#,
            ]),
            url: endpoint
        )

        let recorder = Recorder()
        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: recorder.chunk,
            onThought: recorder.thought
        )

        #expect(response.reasoning == "thinking more")
        #expect(response.content == "done")
        #expect(recorder.thoughts == ["thinking ", "more"])
    }

    @Test("reasoning_content wins when both keys are present")
    func reasoningContentWins() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([#"{"choices":[{"delta":{"reasoning_content":"A","reasoning":"B"}}]}"#]),
            url: endpoint
        )

        let recorder = Recorder()
        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: recorder.chunk,
            onThought: recorder.thought
        )

        #expect(response.reasoning == "A")
        #expect(recorder.thoughts == ["A"])
    }

    @Test("tool call fragments accumulate across chunks")
    func toolCallFragments() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"run_"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"command","arguments":"{\"co"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"mmand\": \"ls\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_def","function":{"name":"read_file","arguments":"{\"path\": \"/tmp\"}"}}]}}]}"#,
            ]),
            url: endpoint
        )

        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: { _ in },
            onThought: { _ in }
        )

        #expect(response.toolCalls.count == 2)
        #expect(response.toolCalls[0].id == "call_abc")
        #expect(response.toolCalls[0].function.name == "run_command")
        #expect(response.toolCalls[0].function.arguments == #"{"command": "ls"}"#)
        #expect(response.toolCalls[1].id == "call_def")
        #expect(response.toolCalls[1].function.name == "read_file")
        #expect(response.toolCalls[1].function.arguments == #"{"path": "/tmp"}"#)
    }

    @Test("tool calls without an id get a generated one")
    func defaultToolCallId() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"{}"}}]}}]}"#]),
            url: endpoint
        )

        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: { _ in },
            onThought: { _ in }
        )

        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].id == "call_0")
    }

    @Test("fragments without a name are dropped")
    func namelessFragmentsDropped() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            sse([
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"partial"}}]}}]}"#,
                #"{"choices":[{"delta":{"content":"ok"}}]}"#,
            ]),
            url: endpoint
        )

        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: { _ in },
            onThought: { _ in }
        )

        #expect(response.toolCalls.isEmpty)
        #expect(response.content == "ok")
    }

    @Test("non-data lines and malformed JSON are ignored")
    func ignoredLines() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE(
            """
            : keep-alive

            data: not json
            data: {"choices":[{"delta":{"content":"ok"}}]}
            """,
            url: endpoint
        )

        let response = try await makeClient().complete(
            messages: [userMessage],
            tools: [],
            slotId: nil,
            onContent: { _ in },
            onThought: { _ in }
        )

        #expect(response.content == "ok")
    }

    @Test("an empty stream is a bad response")
    func emptyStream() async {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE("data: [DONE]", url: endpoint)

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected LLMError.badResponse")
        } catch LLMError.badResponse {
            // Expected.
        } catch {
            Issue.record("expected LLMError.badResponse, got \(error)")
        }
    }

    // MARK: - Errors

    @Test("non-2xx responses throw httpStatus with the body")
    func httpError() async {
        StubURLProtocol.reset()
        StubURLProtocol.serveSSE("server exploded", url: endpoint, statusCode: 500)

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected LLMError.httpStatus")
        } catch LLMError.httpStatus(let code, let body) {
            #expect(code == 500)
            #expect(body == "server exploded\n")
        } catch {
            Issue.record("expected LLMError.httpStatus, got \(error)")
        }
    }

    @Test("a non-HTTP response is a bad response")
    func nonHTTPResponse() async {
        StubURLProtocol.reset()
        StubURLProtocol.behavior = .raw(
            URLResponse(url: endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        )

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected LLMError.badResponse")
        } catch LLMError.badResponse {
            // Expected.
        } catch {
            Issue.record("expected LLMError.badResponse, got \(error)")
        }
    }

    @Test("a cancelled request throws CancellationError")
    func cancelledRequest() async {
        StubURLProtocol.reset()
        StubURLProtocol.behavior = .fail(URLError(.cancelled))

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test("a cancelled stream throws CancellationError")
    func cancelledStream() async {
        StubURLProtocol.reset()
        StubURLProtocol.serveThenFail(
            URLError(.cancelled),
            url: endpoint,
            body: sse([#"{"choices":[{"delta":{"content":"par"}}]}"#])
        )

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test("a dropped stream throws streamInterrupted")
    func droppedStream() async {
        StubURLProtocol.reset()
        StubURLProtocol.serveThenFail(
            URLError(.networkConnectionLost),
            url: endpoint,
            body: sse([#"{"choices":[{"delta":{"content":"par"}}]}"#])
        )

        do {
            _ = try await makeClient().complete(
                messages: [userMessage],
                tools: [],
                slotId: nil,
                onContent: { _ in },
                onThought: { _ in }
            )
            Issue.record("expected LLMError.streamInterrupted")
        } catch LLMError.streamInterrupted {
            // Expected.
        } catch {
            Issue.record("expected LLMError.streamInterrupted, got \(error)")
        }
    }
}
