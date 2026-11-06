//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Fixtures.swift
//

import Foundation
import Helpers
import Logger
import Stores
import Tools

@testable import Agent

// MARK: - Loggers

/// A logger that swallows all messages.
struct NoOpLogger: Loggable {
    func debug(_ message: String) {}
}

// MARK: - Stream Recorder

/// Collects the chunks, thoughts, and JSON-RPC notifications an agent
/// turn emits, for assertions.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _chunks: [String] = []
    private var _thoughts: [String] = []
    private var _jsons: [[String: Any]] = []

    var chunks: [String] { lock.withLock { _chunks } }
    var thoughts: [String] { lock.withLock { _thoughts } }
    var jsons: [[String: Any]] { lock.withLock { _jsons } }

    func chunk(_ text: String) { lock.withLock { _chunks.append(text) } }
    func thought(_ text: String) { lock.withLock { _thoughts.append(text) } }
    func json(_ object: [String: Any]) { lock.withLock { _jsons.append(object) } }

    /// The `update` payloads of every `session/update` notification, in order.
    var sessionUpdates: [[String: Any]] {
        jsons.compactMap { object in
            guard object["method"] as? String == "session/update",
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any]
            else { return nil }
            return update
        }
    }

    /// The `session/update` payloads whose `sessionUpdate` field is `type`.
    func updates(_ type: String) -> [[String: Any]] {
        sessionUpdates.filter { $0["sessionUpdate"] as? String == type }
    }
}

// MARK: - Fake LLM Client

/// One scripted outcome for the next LLM call.
enum ScriptedResponse: Sendable {
    case response(LLMResponse)
    case failure(Error)
    /// Suspends until the running task is cancelled, then throws
    /// CancellationError — used to make cancellation tests deterministic.
    case hang
}

/// A recorded LLM call: the exact inputs the agent passed.
struct FakeLLMCall: Sendable {
    let messages: [ChatMessage]
    let tools: [ToolDefinition]
    let slotId: Int?
}

/// A scripted LLMClient: returns outcomes in order (or repeats `repeating`
/// once the queue is empty), records every call, and replays the response's
/// content and reasoning through the stream callbacks.
final class FakeLLMClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ScriptedResponse]
    private let repeating: ScriptedResponse?
    private var _calls: [FakeLLMCall] = []

    init(responses: [ScriptedResponse], repeating: ScriptedResponse? = nil) {
        self.queue = responses
        self.repeating = repeating
    }

    var callCount: Int { lock.withLock { _calls.count } }
    var calls: [FakeLLMCall] { lock.withLock { _calls } }

    func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        slotId: Int?,
        onContent: @escaping @Sendable (String) -> Void,
        onThought: @escaping @Sendable (String) -> Void
    ) async throws -> LLMResponse {
        let outcome: ScriptedResponse = lock.withLock {
            _calls.append(FakeLLMCall(messages: messages, tools: tools, slotId: slotId))
            if queue.isEmpty {
                return repeating ?? .failure(FakeLLMError.exhausted)
            }
            return queue.removeFirst()
        }

        switch outcome {
        case .response(let response):
            if let content = response.content { onContent(content) }
            if let reasoning = response.reasoning { onThought(reasoning) }
            return response
        case .failure(let error):
            throw error
        case .hang:
            // Suspend until the task is cancelled; the sleep throws
            // CancellationError, which the agent treats as session/cancel.
            try await Task.sleep(for: .seconds(3_600))
            throw FakeLLMError.exhausted
        }
    }
}

enum FakeLLMError: Error {
    case exhausted
}

// MARK: - Fake Tool Provider

/// A recorded tool execution.
struct FakeToolCall: Sendable {
    let name: String
    let argsJSON: String
    let cwd: String
    let sessionId: String
}

/// A ToolProvider with canned definitions and results. Records every
/// execution and prepare call, and can run a hook after each execution
/// (e.g. to cancel the agent's task mid-batch).
final class FakeToolProvider: ToolProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let toolDefinitions: [ToolDefinition]
    private let results: [String: String]
    private var _executions: [FakeToolCall] = []
    private var _preparedCwds: [String] = []
    private var _onExecute: (@Sendable (FakeToolCall) -> Void)?

    init(tools: [ToolDefinition] = [], results: [String: String] = [:]) {
        self.toolDefinitions = tools
        self.results = results
    }

    var executions: [FakeToolCall] { lock.withLock { _executions } }
    var preparedCwds: [String] { lock.withLock { _preparedCwds } }

    /// Runs after each recorded execution.
    var onExecute: (@Sendable (FakeToolCall) -> Void)? {
        get { lock.withLock { _onExecute } }
        set { lock.withLock { _onExecute = newValue } }
    }

    func definitions() async -> [ToolDefinition] {
        toolDefinitions
    }

    func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async -> String {
        let call = FakeToolCall(name: name, argsJSON: argsJSON, cwd: cwd, sessionId: sessionId)
        let (hook, result): ((@Sendable (FakeToolCall) -> Void)?, String) = lock.withLock {
            _executions.append(call)
            return (_onExecute, results[name] ?? "Result of \(name)")
        }
        hook?(call)
        return result
    }

    func prepare(cwd: String) async {
        lock.withLock { _preparedCwds.append(cwd) }
    }
}

// MARK: - Temp Directory

/// A per-test temporary directory, removed when the instance goes away.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terrapincode-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a file (and any missing parent directories) with `contents`.
    @discardableResult
    func writeFile(_ path: String, contents: String) -> URL {
        let url = self.url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Task Synchronization

/// A one-shot async gate for sequencing test tasks deterministically.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.withLock { isOpen = true }
    }

    func wait() async {
        while !lock.withLock({ isOpen }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Holds a reference to a running task so test doubles can cancel it.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>?) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}

// MARK: - HTTP Stub

/// A URLProtocol that serves canned responses, so OpenAICompatibleClient
/// can be tested without a real server.
final class StubURLProtocol: URLProtocol {
    /// What to do with the next request.
    enum Behavior {
        /// Serve `response` with `body`.
        case serve(response: HTTPURLResponse, body: Data)
        /// Serve `response` with `body`, then fail with `error` mid-stream.
        case serveThenFail(response: HTTPURLResponse, body: Data, error: URLError)
        /// Fail the request immediately with `error`.
        case fail(URLError)
        /// Serve a non-HTTP response (exercises the badResponse path).
        case raw(URLResponse)
    }

    nonisolated(unsafe) static var behavior: Behavior = .serve(
        response: StubURLProtocol.okResponse(url: URL(string: "http://stub.local")!),
        body: Data()
    )
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []

    /// Resets the stub to a plain 200 with an empty body.
    static func reset() {
        behavior = .serve(
            response: StubURLProtocol.okResponse(url: URL(string: "http://stub.local")!),
            body: Data()
        )
        capturedRequests = []
        capturedBodies = []
    }

    /// Serves an SSE body with the given status code.
    static func serveSSE(_ body: String, url: URL, statusCode: Int = 200) {
        behavior = .serve(
            response: StubURLProtocol.okResponse(url: url, statusCode: statusCode),
            body: Data(body.utf8)
        )
    }

    /// Serves `body`, then fails mid-stream with `error`.
    static func serveThenFail(_ error: URLError, url: URL, body: String) {
        behavior = .serveThenFail(
            response: StubURLProtocol.okResponse(url: url),
            body: Data(body.utf8),
            error: error
        )
    }

    private static func okResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequests.append(request)
        Self.capturedBodies.append(Self.bodyData(from: request))

        switch Self.behavior {
        case .serve(let response, let body):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .serveThenFail(let response, let body, let error):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocol(self, didFailWithError: error)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .raw(let response):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession moves the request body into a stream by the time the
    /// protocol sees it, so read it back out.
    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A URLSession that routes every request through StubURLProtocol.
func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - Agent Harness

/// The standard test templates: one per client kind, with every placeholder
/// separated by "|" so individual blocks are easy to assert on.
let testTemplates: [ClientKind: String] = [
    .xcode: "XCODE {{CWD}}|{{TERMINAL_TOOLS}}|{{NETWORK_STATUS}}|{{SKILLS}}|{{CUSTOM_INSTRUCTIONS}}",
    .generic(name: "unknown"): "GENERIC {{CWD}}|{{TERMINAL_TOOLS}}|{{NETWORK_STATUS}}|{{SKILLS}}|{{CUSTOM_INSTRUCTIONS}}",
]

/// A skill used to assert the catalog block in the system prompt.
let testSkill = Skill(
    name: "test-skill",
    description: "A test skill",
    path: "/tmp/SKILL.md",
    directory: "/tmp"
)

/// A minimal tool definition named `name`.
func testToolDefinition(_ name: String) -> ToolDefinition {
    ToolDefinition(
        function: FunctionDefinition(
            name: name,
            description: "Test tool \(name)",
            parameters: [:]
        )
    )
}

/// Wires an Agent with test doubles and hands back handles to everything
/// the tests need to assert on.
struct AgentHarness {
    let agent: Agent
    let store: SessionStore
    let provider: FakeToolProvider
    let llm: FakeLLMClient
    let temp: TempDirectory
    let sessionId: String
    let cwd: String

    /// Runs one agent turn, recording all output into `recorder`.
    func run(
        prompt: String,
        client: ClientKind = .xcode,
        supportsCompaction: Bool = false,
        tools: [ToolDefinition] = [],
        recorder: Recorder
    ) async {
        await agent.run(
            prompt: prompt,
            sessionId: sessionId,
            cwd: cwd,
            client: client,
            supportsCompaction: supportsCompaction,
            tools: tools,
            onChunk: recorder.chunk,
            onThought: recorder.thought,
            onSendJSON: recorder.json
        )
    }
}

func makeAgentHarness(
    llm: FakeLLMClient,
    tools: [ToolDefinition] = [],
    results: [String: String] = [:],
    contextWindow: Int = 10_000,
    templates: [ClientKind: String] = testTemplates,
    skills: [Skill] = [],
    slotCount: Int = 1
) -> AgentHarness {
    let temp = TempDirectory()
    let store = SessionStore(
        logger: NoOpLogger(),
        sessionsDirectory: temp.url.appendingPathComponent("sessions")
    )
    let provider = FakeToolProvider(tools: tools, results: results)
    let agent = Agent(
        llmClient: llm,
        toolRegistry: ToolRegistry([provider]),
        sessionStore: store,
        contextWindow: contextWindow,
        systemPromptTemplates: templates,
        skillCatalog: { _ in SkillCatalog(skills: skills) },
        logger: NoOpLogger(),
        slotCount: slotCount,
        networkMonitor: NetworkMonitor()
    )
    return AgentHarness(
        agent: agent,
        store: store,
        provider: provider,
        llm: llm,
        temp: temp,
        sessionId: "test-session",
        cwd: temp.url.path
    )
}
