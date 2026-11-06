//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPServer.swift
//

import Agent
import Foundation
import Logger
import Stores
import Tools

/// ACP (Agent Client Protocol) server: reads JSON-RPC messages from stdin,
/// dispatches them to the agent, and writes JSON-RPC responses to stdout.
final class ACPServer: Sendable {
    private let agent: Agent
    private let sessionStore: SessionStore
    private let toolRegistry: ToolRegistry
    private let xcodeBridge: XcodeMCPBridgeClient
    private let defaultClient: ClientKind
    private let logger: Loggable
    private let clientChannel: ClientChannel
    private let clientTools: ACPClientTools
    private let stdoutLock = NSLock()
    // In-flight session/prompt tasks, keyed by session id. Guarded by
    // taskLock so session/cancel can find and stop the running turn.
    private let taskLock = NSLock()
    private nonisolated(unsafe) var promptTasks: [String: PromptTaskBox] = [:]
    // Written once in handleInitialize (the first message the client sends)
    // and only read afterwards, so no locking is needed.
    private nonisolated(unsafe) var clientKind: ClientKind = .xcode
    // Whether the client advertised the ACP `session.compaction` capability,
    // which gates compaction_update notifications. Written once in
    // handleInitialize and only read afterwards, so no locking is needed.
    private nonisolated(unsafe) var supportsCompaction = false
    // Set once when the Xcode MCP bridge is started; the stdin loop is
    // sequential, so no locking is needed.
    private nonisolated(unsafe) var xcodeBridgeReady = false

    init(
        agent: Agent,
        sessionStore: SessionStore,
        toolRegistry: ToolRegistry,
        xcodeBridge: XcodeMCPBridgeClient,
        clientChannel: ClientChannel,
        clientTools: ACPClientTools,
        defaultClient: ClientKind,
        logger: Loggable
    ) {
        self.agent = agent
        self.sessionStore = sessionStore
        self.toolRegistry = toolRegistry
        self.xcodeBridge = xcodeBridge
        self.defaultClient = defaultClient
        self.logger = logger
        self.clientChannel = clientChannel
        self.clientTools = clientTools
        self.clientKind = defaultClient

        // Deliver agent-initiated client requests (fs/*, terminal/*) to stdout.
        clientChannel.setSender { [weak self] json in
            self?.sendJSON(json)
        }
    }

    /// Runs the stdin read/parse/dispatch loop until stdin closes.
    func run() async {
        while let line = readLine() {
            await handle(line)
        }
    }

    // MARK: - Dispatch

    private func handle(_ line: String) async {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        logger.debug("IN  <--- \(line)")

        guard let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return }

        let method = json["method"] as? String ?? ""
        let hasId = json.keys.contains("id") && !(json["id"] is NSNull)
        // Preserves the id's original JSON type so the response echoes it
        // exactly. JSON-RPC 2.0 requires type-strict id matching: a numeric
        // request id answered with a string is never correlated by strict
        // clients (Android Studio times out and sends $/cancel_request).
        let reqId: RPCID? = hasId ? json["id"].map(RPCID.init) : nil

        // A message with no method but an id is a response to a request the
        // agent sent to the client (fs/*, terminal/*). Route it to the
        // awaiting ClientChannel caller.
        if method.isEmpty, hasId {
            let answered = await clientChannel.handleIncoming(json)
            if !answered {
                logger.debug(
                    "Unmatched client response id: \(reqId.map { "\($0.value)" } ?? "?")"
                )
            }
            return
        }

        switch method {
        case "initialize":
            handleInitialize(json: json, hasId: hasId, reqId: reqId)
        case "session/new":
            await handleNewSession(json: json, hasId: hasId, reqId: reqId)
        case "session/load":
            await handleLoadSession(json: json, hasId: hasId, reqId: reqId)
        case "session/prompt":
            await handlePrompt(json: json, hasId: hasId, reqId: reqId)
        case "session/delete":
            await handleDeleteSession(json: json, hasId: hasId, reqId: reqId)
        case "session/cancel":
            await handleCancel(json: json)
        default:
            if hasId, let reqId {
                sendJSON([
                    "jsonrpc": "2.0",
                    "id": reqId.value,
                    "result": [:],
                ])
            }
        }
    }

    private func handleInitialize(json: [String: Any], hasId: Bool, reqId: RPCID?) {
        guard hasId, let reqId else { return }

        // Negotiate the client capabilities that gate the native ACP tools
        // (fs/* and terminal/*). Omitted capabilities are unsupported.
        let params = json["params"] as? [String: Any]
        let clientCapabilities = params?["clientCapabilities"] as? [String: Any]
        let fs = clientCapabilities?["fs"] as? [String: Any]
        clientTools.updateCapabilities(
            Capabilities(
                readTextFile: (fs?["readTextFile"] as? Bool) ?? false,
                writeTextFile: (fs?["writeTextFile"] as? Bool) ?? false,
                terminal: (clientCapabilities?["terminal"] as? Bool) ?? false
            )
        )

        // The client opts in to compaction_update notifications by
        // advertising the session.compaction capability. Per the ACP spec the
        // agent MUST NOT send them without it; we fall back to an agent
        // message instead.
        let sessionCaps = clientCapabilities?["session"] as? [String: Any]
        supportsCompaction =
            (sessionCaps?["compaction"] as? [String: Any]) != nil
                || (sessionCaps?["compaction"] as? Bool) == true

        // Identify the connecting client (clientInfo is SHOULD-level in the
        // ACP spec) so the agent can pick the matching system prompt and
        // toolset.
        let clientInfo = params?["clientInfo"] as? [String: Any]
        clientKind = ClientKind.detect(
            clientInfo: clientInfo,
            environment: ProcessInfo.processInfo.environment,
            fallback: defaultClient
        )
        logger.debug("Detected ACP client: \(clientKind)")

        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId.value,
            "result": [
                "protocolVersion": 1,
                "agentCapabilities": [
                    "loadSession": true,
                    // Per the ACP spec, session capability markers must be
                    // JSON objects: "delete": {} advertises session/delete
                    // support. An empty array is a type mismatch that strict
                    // clients (Android Studio) fail to deserialize.
                    "sessionCapabilities": ["delete": [:]],
                ],
                "agentInfo": ["name": "TerrapinCode", "version": "1.0.0"],
                "authMethods": [],
            ],
        ])
    }

    private func handleNewSession(
        json: [String: Any],
        hasId: Bool,
        reqId: RPCID?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let cwd = Self.extractParam(params, key: "cwd")
        let newSessionId = UUID().uuidString

        if !cwd.isEmpty {
            await sessionStore.setCWD(cwd, for: newSessionId)
        }

        // Xcode-only setup: spawn the mcpbridge and register its tools the
        // first time an Xcode session is created or loaded.
        await ensureXcodeBridge()

        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId.value,
            "result": ["sessionId": newSessionId],
        ])
    }

    /// Spawns the Xcode MCP bridge and registers its tools with the registry.
    /// Failures are logged and swallowed so the agent degrades to the
    /// client-agnostic toolset instead of crashing.
    private func setupXcodeBridge() async {
        do {
            try await xcodeBridge.start()
        } catch {
            logger.debug("Xcode MCP bridge failed to start: \(error)")
            return
        }
        let bridgeTools = await xcodeBridge.fetchTools()
        toolRegistry.add(xcodeBridge)
        logger.debug("Xcode MCP bridge ready with \(bridgeTools.count) tools")
    }

    /// Spawns the Xcode MCP bridge on first use (session/new or session/load)
    /// for Xcode clients.
    private func ensureXcodeBridge() async {
        guard clientKind == .xcode, !xcodeBridgeReady else { return }
        xcodeBridgeReady = true
        await setupXcodeBridge()
    }

    /// Handles session/load: restores a persisted session and replays its
    /// conversation to the client as session/update notifications, per the
    /// ACP spec. The response is sent only after the replay is complete.
    private func handleLoadSession(
        json: [String: Any],
        hasId: Bool,
        reqId: RPCID?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""
        let clientCwd = Self.extractParam(params, key: "cwd")

        guard !sessionId.isEmpty else {
            sendError(reqId: reqId, code: -32602, message: "Missing sessionId")
            return
        }

        guard await sessionStore.loadSession(for: sessionId) else {
            sendError(
                reqId: reqId,
                code: -32002,
                message: "Session not found: \(sessionId)"
            )
            return
        }

        // Fall back to the client-provided cwd when the stored session has none.
        if await sessionStore.getCWD(for: sessionId) == nil, !clientCwd.isEmpty {
            await sessionStore.setCWD(clientCwd, for: sessionId)
        }

        await ensureXcodeBridge()

        // Replay the conversation so the client can display it. Tool calls
        // and tool results are not replayed; the full history is retained
        // server-side for the model's context.
        if let history = await sessionStore.history(for: sessionId) {
            for message in history {
                switch message.role {
                case "user":
                    if let text = message.content, !text.isEmpty {
                        sendJSON([
                            "jsonrpc": "2.0",
                            "method": "session/update",
                            "params": [
                                "sessionId": sessionId,
                                "update": [
                                    "sessionUpdate": "user_message_chunk",
                                    "content": [
                                        "type": "text",
                                        "text": text,
                                    ],
                                ],
                            ],
                        ])
                    }
                case "assistant":
                    if let thought = message.reasoning, !thought.isEmpty {
                        sendThoughtChunk(sessionId: sessionId, text: thought)
                    }
                    if let text = message.content, !text.isEmpty {
                        sendChunk(sessionId: sessionId, text: text)
                    }
                default:
                    break
                }
            }
        }

        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId.value,
            "result": ["sessionId": sessionId],
        ])
    }

    /// Handles session/delete: removes the persisted session. Per the ACP
    /// spec, deleting an unknown or already-deleted session succeeds silently.
    private func handleDeleteSession(
        json: [String: Any],
        hasId: Bool,
        reqId: RPCID?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""

        guard !sessionId.isEmpty else {
            sendError(reqId: reqId, code: -32602, message: "Missing sessionId")
            return
        }

        await sessionStore.deleteSession(for: sessionId)
        releaseLeakedTerminals(for: sessionId)

        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId.value,
            "result": [:],
        ])
    }

    private func handlePrompt(
        json: [String: Any],
        hasId: Bool,
        reqId: RPCID?
    ) async {
        guard hasId, let reqId else { return }
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""
        let userPrompt = Self.sanitizeXcodePrompt(Self.extractParam(params, key: "prompt"))

        // Resolve working directory (fallback to standard user home directory)
        let cwd =
            await sessionStore.getCWD(for: sessionId)
            ?? Self.extractParam(params, key: "cwd")
        
        let tools = await self.toolRegistry.definitions()

        let box = PromptTaskBox()
        let task = Task.detached {
            await self.agent.run(
                prompt: userPrompt,
                sessionId: sessionId,
                cwd: cwd,
                client: self.clientKind,
                supportsCompaction: self.supportsCompaction,
                tools: tools,
                onChunk: { text in
                    self.sendChunk(sessionId: sessionId, text: text)
                },
                onThought: { text in
                    self.sendThoughtChunk(sessionId: sessionId, text: text)
                },
                onSendJSON: { json in
                    self.sendJSON(json)
                }
            )

            // Complete the ACP prompt request. Per the ACP spec, a turn
            // stopped by session/cancel reports "cancelled" here; the
            // cancel notification itself gets no response.
            let stopReason = Task.isCancelled ? "cancelled" : "end_turn"
            self.sendJSON([
                "jsonrpc": "2.0",
                "id": reqId.value,
                "result": [
                    "stopReason": stopReason
                ],
            ])

            self.removePromptTask(box, for: sessionId)
        }
        box.task = task

        taskLock.withLock {
            // A new prompt supersedes any in-flight turn for this session.
            promptTasks[sessionId]?.task?.cancel()
            promptTasks[sessionId] = box
        }
    }

    /// Handles the session/cancel notification: stops the in-flight prompt
    /// turn for the session. Sends no response (it is a notification); the
    /// original session/prompt request is answered with "cancelled".
    private func handleCancel(json: [String: Any]) async {
        let params = json["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? ""

        taskLock.withLock {
            promptTasks[sessionId]?.task?.cancel()
        }

        releaseLeakedTerminals(for: sessionId)
    }

    /// Releases any terminals the session still holds. A cancelled or
    /// deleted turn never gets to terminal_release them itself, and the ACP
    /// spec makes the agent responsible for releasing terminals.
    ///
    /// Runs detached: the stdin loop must keep reading so the client's
    /// responses to the release requests can be routed back to the awaiting
    /// ClientChannel callers (awaiting them inline would block the loop
    /// until every request timed out).
    private func releaseLeakedTerminals(for sessionId: String) {
        Task.detached { [clientTools, logger] in
            let released = await clientTools.releaseAllTerminals(for: sessionId)
            if released > 0 {
                logger.debug("Released \(released) leaked terminal(s) for session \(sessionId)")
            }
        }
    }

    private func removePromptTask(_ box: PromptTaskBox, for sessionId: String) {
        taskLock.withLock {
            // Only remove if this box is still the current one for the session.
            if promptTasks[sessionId] === box {
                promptTasks[sessionId] = nil
            }
        }
    }

    // MARK: - Output

    /// Sends a JSON-RPC error response for a request.
    private func sendError(reqId: RPCID, code: Int, message: String) {
        sendJSON([
            "jsonrpc": "2.0",
            "id": reqId.value,
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func sendJSON(_ dictionary: [String: Any]) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }

        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
            let jsonString = String(data: data, encoding: .utf8)
        else { return }
        logger.debug("OUT ---> \(jsonString)")
        print(jsonString)
        fflush(stdout)
    }

    private func sendChunk(sessionId: String, text: String) {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": [
                        "type": "text",
                        "text": text,
                    ],
                ],
            ],
        ])
    }

    private func sendThoughtChunk(sessionId: String, text: String) {
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "agent_thought_chunk",
                    "content": [
                        "type": "text",
                        "text": text,
                    ],
                ],
            ],
        ])
    }

    // MARK: - Helpers

    /// Xcode prepends a "Project structure" block to prompts that instructs
    /// the model to use XcodeRead/XcodeWrite/XcodeGrep/XcodeGlob to interact
    /// with files. We expose native ACP file tools instead, so strip that
    /// instruction to keep the model from calling tools it cannot reach.
    private static func sanitizeXcodePrompt(_ prompt: String) -> String {
        prompt.replacing(
            ". Use XcodeRead, XcodeWrite, XcodeGrep, and XcodeGlob to interact with these files):",
            with: "):"
        )
    }

    /// Extracts a prompt string or path parameter from ACP params.
    private static func extractParam(_ params: [String: Any]?, key: String) -> String {
        guard let params = params else { return "" }
        if let str = params[key] as? String { return str }
        if let blocks = params[key] as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(
                separator: "\n"
            )
        }
        return ""
    }
}

/// Reference wrapper around an in-flight prompt task so it can be compared
/// by identity (Task is a struct) and captured before the task exists.
/// The `task` slot is written once, before the task can observe the box,
/// and only read under ACPServer's taskLock.
private final class PromptTaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}

/// Wraps a JSON-RPC request id, preserving its original JSON type so the
/// response echoes it exactly. JSON-RPC 2.0 requires type-strict id
/// matching: a numeric request id answered with a string is never
/// correlated by strict clients (Android Studio times out and sends
/// $/cancel_request). The wrapped value is an immutable JSON value
/// (String or NSNumber), so unchecked Sendable is sound.
private struct RPCID: @unchecked Sendable {
    let value: Any
}
