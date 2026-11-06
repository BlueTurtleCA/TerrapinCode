//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Agent.swift
//

import Foundation
import Helpers
import Logger
import Stores
import Tools

/// Drives the agentic execution loop: prompt the model, dispatch tool calls,
/// and repeat until the model produces a final answer.
public struct Agent: Sendable {
    private let llmClient: LLMClient
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let contextWindow: Int
    private let systemPromptTemplates: [ClientKind: String]
    private let skillCatalog: @Sendable (String) -> SkillCatalog
    private let logger: Loggable
    private let slotCount: Int
    private let networkMonitor: NetworkMonitor

    public init(
        llmClient: LLMClient,
        toolRegistry: ToolRegistry,
        sessionStore: SessionStore,
        contextWindow: Int,
        systemPromptTemplates: [ClientKind: String],
        skillCatalog: @escaping @Sendable (String) -> SkillCatalog = { _ in SkillCatalog(skills: []) },
        logger: Loggable,
        slotCount: Int = 1,
        networkMonitor: NetworkMonitor = .shared
    ) {
        self.llmClient = llmClient
        self.toolRegistry = toolRegistry
        self.sessionStore = sessionStore
        self.contextWindow = contextWindow
        self.systemPromptTemplates = systemPromptTemplates
        self.skillCatalog = skillCatalog
        self.logger = logger
        self.slotCount = slotCount
        self.networkMonitor = networkMonitor
    }

    /// Runs a full agent turn for `prompt` within `sessionId`.
    /// `supportsCompaction` reflects whether the client advertised the ACP
    /// `session.compaction` capability, which gates `compaction_update`
    /// notifications.
    public func run(
        prompt: String,
        sessionId: String,
        cwd: String,
        client: ClientKind,
        supportsCompaction: Bool,
        tools: [ToolDefinition],
        onChunk: @escaping @Sendable (String) -> Void,
        onThought: @escaping @Sendable (String) -> Void,
        onSendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async {
        // /debug <file>: replay raw JSON objects from a file straight to the
        // client via sendJSON, bypassing the LLM entirely.
        if let debugPath = Self.debugFilePath(in: prompt) {
            await runDebugReplay(
                path: debugPath,
                cwd: cwd,
                sessionId: sessionId,
                onChunk: onChunk,
                onSendJSON: onSendJSON
            )
            return
        }

        // /compact: manually compact the session's history, bypassing the
        // token threshold, for sessions that are growing but not yet over
        // the limit.
        if Self.isCompactCommand(prompt) {
            await runManualCompaction(
                sessionId: sessionId,
                supportsCompaction: supportsCompaction,
                onChunk: onChunk,
                onSendJSON: onSendJSON
            )
            return
        }

        // Check connectivity before building the prompt so a session that
        // starts offline gets the warning in its system prompt.
        let online = await networkMonitor.isOnline

        var history = await sessionStore.getHistory(
            for: sessionId,
            defaultSystemPrompt: buildSystemPrompt(
                cwd: cwd,
                client: client,
                terminalToolsAvailable: tools.contains { $0.function.name == "run_command" },
                online: online
            )
        )

        // Notify the model when the network state changed since the last
        // turn: web tools are useless while offline, and the model should
        // know when the connection comes back.
        let previousNetworkState = await sessionStore.networkState(for: sessionId)
        if let note = NetworkMonitor.transitionNote(online: online, previous: previousNetworkState) {
            history.append(ChatMessage(role: "user", content: note))
        }
        if previousNetworkState != online {
            await sessionStore.setNetworkState(online, for: sessionId)
        }

        // Record what we believe the context window to be so the persisted
        // session shows the basis for the compaction threshold.
        if await sessionStore.contextWindow(for: sessionId) != contextWindow {
            await sessionStore.setContextWindow(contextWindow, for: sessionId)
        }

        history.append(ChatMessage(role: "user", content: prompt))

        // Pin this session to a stable server slot so the backend (llama.cpp)
        // can reuse its KV cache across turns and only process the delta.
        let slotId = Self.slotId(for: sessionId, count: slotCount)

        // Open the Xcode workspace up front so workspace tools work on the
        // first call and the user's access approval is requested immediately.
        await toolRegistry.prepare(cwd: cwd)

        let maxTurns = 500
        var currentTurn = 0

        while currentTurn < maxTurns {
            // Stop promptly if the client sent session/cancel.
            if Task.isCancelled { break }

            currentTurn += 1

            // Compact history if approaching context window limit, and tell
            // the client when it happens (it is otherwise invisible).
            let compaction = ContextManager.compactHistory(history, maxTokens: contextWindow)
            let usagePercent = contextWindow > 0
                ? Double(compaction.tokensBefore) / Double(contextWindow) * 100
                : 0
            logger.debug(
                "Context: \(compaction.tokensBefore)/\(contextWindow) estimated tokens (\(String(format: "%.1f", usagePercent))%) — session \(sessionId)"
            )
            history = compaction.messages
            if compaction.compacted {
                logger.debug(
                    "Compacted history: removed \(compaction.messagesRemoved) messages (\(compaction.tokensBefore) -> \(compaction.tokensAfter) estimated tokens) — session \(sessionId)"
                )
                reportCompaction(
                    compaction,
                    sessionId: sessionId,
                    supportsCompaction: supportsCompaction,
                    onChunk: onChunk,
                    onSendJSON: onSendJSON
                )
            }

            let response: LLMResponse
            do {
                response = try await llmClient.complete(
                    messages: history,
                    tools: tools,
                    slotId: slotId,
                    onContent: { text in
                        onChunk(text)
                    },
                    onThought: { text in
                        onThought(text)
                    }
                )
            } catch is CancellationError {
                // session/cancel arrived mid-stream; stop quietly.
                break
            } catch LLMError.httpStatus(let code, let body) {
                logger.debug("AI Server \(code) Error Response: \(body)")
                onChunk("⚠️ Error connecting to local AI server.")
                break
            } catch LLMError.streamInterrupted {
                onChunk("⚠️ Connection to AI server dropped mid-response.")
                break
            } catch LLMError.badResponse {
                onChunk("⚠️ Failed to parse response from AI server.")
                break
            } catch {
                onChunk("⚠️ Error during agent turn: \(error.localizedDescription)")
                break
            }

            // Check if model emitted tool calls
            if !response.toolCalls.isEmpty {
                // Record the assistant's tool_calls message in history FIRST,
                // including any reasoning so the prefix stays stable for reuse.
                history.append(
                    ChatMessage(
                        role: "assistant",
                        reasoning: response.reasoning,
                        toolCalls: response.toolCalls
                    )
                )
                
                onSendJSON([
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": [
                        "sessionId": sessionId,
                        "update": [
                            "sessionUpdate": "plan",
                            "entries": [
                                [
                                    "content": "Enable artifacts",
                                    "status": "in_progress"
                                ]
                            ]
                        ]
                    ]
                ])

                // Execute tools and append results back to chat history
                for call in response.toolCalls {
                    // Honor session/cancel between tool calls so the rest of
                    // the batch is skipped. A placeholder result keeps the
                    // history valid (every tool_call needs a tool message).
                    if Task.isCancelled {
                        history.append(
                            ChatMessage(
                                role: "tool",
                                content: "Cancelled by user before this tool ran.",
                                toolCallId: call.id,
                                name: call.function.name
                            )
                        )
                        continue
                    }

                    let result = await toolRegistry.execute(
                        name: call.function.name,
                        argsJSON: call.function.arguments,
                        cwd: cwd,
                        sessionId: sessionId,
                        sendJSON: onSendJSON
                    )
                    
                    history.append(
                        ChatMessage(
                            role: "tool",
                            content: result,
                            toolCallId: call.id,
                            name: call.function.name
                        )
                    )
                }
                
                onSendJSON([
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": [
                        "sessionId": sessionId,
                        "update": [
                            "sessionUpdate": "plan",
                            "entries": [
                                [
                                    "content": "Enable artifacts",
                                    "status": "completed"
                                ]
                            ]
                        ]
                    ]
                ])

                // Loop back to send tool results to the AI server
                continue
            }

            // Final text response from LLM (already streamed via onContent)
            if let content = response.content, !content.isEmpty {
                history.append(
                    ChatMessage(
                        role: "assistant",
                        content: content,
                        reasoning: response.reasoning
                    )
                )
            }

            break
        }

        // Save updated history
        await sessionStore.saveHistory(history, for: sessionId)
    }

    // MARK: - Compaction Reporting

    /// Notifies the client that history was compacted. Clients that
    /// advertised the ACP `session.compaction` capability get a structured
    /// `compaction_update` (stats in `_meta`) followed by a `usage_update`
    /// with the post-compaction context usage. Other clients get a one-line
    /// agent message, the fallback the spec sanctions.
    private func reportCompaction(
        _ compaction: ContextManager.CompactionResult,
        sessionId: String,
        supportsCompaction: Bool,
        onChunk: @escaping @Sendable (String) -> Void,
        onSendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) {
        let freed = compaction.tokensBefore - compaction.tokensAfter
        let summary = """
            Compacted conversation: removed \(compaction.messagesRemoved) older messages (~\(Self.formatTokens(freed)) tokens); kept the most recent \(compaction.messagesKept) messages.
            """

        guard supportsCompaction else {
            onChunk("ℹ️ \(summary)")
            return
        }

        onSendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "compaction_update",
                    "compactionId": "cmp_\(UUID().uuidString)",
                    "status": "completed",
                    "summary": [
                        ["type": "text", "text": summary],
                    ],
                    "_meta": [
                        "messagesRemoved": compaction.messagesRemoved,
                        "messagesKept": compaction.messagesKept,
                        "tokensBefore": compaction.tokensBefore,
                        "tokensAfter": compaction.tokensAfter,
                    ],
                ],
            ],
        ])

        // Report the post-compaction context usage so clients with a context
        // meter can update. usage_update requires no client capability.
        onSendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "usage_update",
                    "used": compaction.tokensAfter,
                    "size": contextWindow,
                ],
            ],
        ])
    }

    /// Formats a token count for user display (e.g. 61204 -> "61.2k").
    private static func formatTokens(_ tokens: Int) -> String {
        guard tokens >= 1000 else { return "\(tokens)" }
        return String(format: "%.1fk", Double(tokens) / 1000)
    }

    // MARK: - Manual Compaction

    /// Returns true when the prompt is the /compact command, which manually
    /// compacts the session's history regardless of the token threshold.
    private static func isCompactCommand(_ prompt: String) -> Bool {
        guard let last = prompt.split(whereSeparator: \.isNewline).last else { return false }
        return last.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact"
    }

    /// Compacts the session's history on demand (/compact) and reports the
    /// outcome to the client. Unlike the automatic path, the token threshold
    /// is bypassed so a session that is growing but not yet over the limit
    /// can still be trimmed.
    private func runManualCompaction(
        sessionId: String,
        supportsCompaction: Bool,
        onChunk: @escaping @Sendable (String) -> Void,
        onSendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async {
        guard
            let history = await sessionStore.history(for: sessionId),
            !history.isEmpty
        else {
            onChunk("ℹ️ /compact: no conversation to compact yet.")
            return
        }

        let compaction = ContextManager.compactHistory(
            history,
            maxTokens: contextWindow,
            force: true
        )
        logger.debug(
            "/compact: \(compaction.tokensBefore) estimated tokens, compacted=\(compaction.compacted), removed=\(compaction.messagesRemoved) — session \(sessionId)"
        )

        guard compaction.compacted else {
            onChunk(
                "ℹ️ /compact: only \(history.count) messages in the conversation; nothing to compact."
            )
            return
        }

        guard compaction.messagesRemoved > 0 else {
            onChunk(
                "ℹ️ /compact: the conversation already fits within the keep budget (\(Self.formatTokens(compaction.tokensAfter)) estimated tokens); nothing was dropped."
            )
            return
        }

        await sessionStore.saveHistory(compaction.messages, for: sessionId)
        reportCompaction(
            compaction,
            sessionId: sessionId,
            supportsCompaction: supportsCompaction,
            onChunk: onChunk,
            onSendJSON: onSendJSON
        )
    }

    // MARK: - Debug Replay

    /// Parses a `/debug <file>` prompt into a file path, or nil when the
    /// prompt is not a debug command.
    private static func debugFilePath(in prompt: String) -> String? {
        let trimmed = prompt.split(whereSeparator: \.isNewline ).last!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/debug") else { return nil }
        let path = trimmed
            .dropFirst("/debug".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Reads `path`, splits its contents on `---` delimiters, and sends each
    /// JSON object to the client via `onSendJSON`. No LLM call is made and
    /// the session history is left untouched.
    private func runDebugReplay(
        path: String,
        cwd: String,
        sessionId: String,
        onChunk: @escaping @Sendable (String) -> Void,
        onSendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async {
        let filePath = path.hasPrefix("/") ? path : cwd + "/" + path

        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            logger.debug("/debug: could not read \(filePath)")
            onChunk("⚠️ /debug: could not read file: \(filePath)")
            return
        }

        let uuid = UUID().uuidString
        
        let chunks = contents
            .components(separatedBy: "---")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "[SessionId]", with: sessionId, options: .caseInsensitive)
                .replacingOccurrences(of: "[UUID]", with: uuid, options: .caseInsensitive) }
            .filter { !$0.isEmpty }

        guard !chunks.isEmpty else {
            onChunk("⚠️ /debug: no JSON objects found in \(filePath)")
            return
        }

        var sent = 0
        for (index, chunk) in chunks.enumerated() {
            guard
                let data = chunk.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                logger.debug("/debug: skipping invalid JSON at object #\(index + 1)")
                onChunk("⚠️ /debug: skipping invalid JSON at object #\(index + 1)")
                continue
            }
            logger.debug("/debug: sending object #\(index + 1) of \(chunks.count)")
            onSendJSON(object)
            sent += 1
        }

        onChunk("✅ /debug: sent \(sent) of \(chunks.count) JSON object(s) from \(filePath)")
    }

    // MARK: - Prompt Building

    private func buildSystemPrompt(cwd: String, client: ClientKind, terminalToolsAvailable: Bool, online: Bool) -> String {
        var customInstructionsBlock = ""

        if let agentInstructions = loadWorkspaceInstructions(from: cwd) {
            customInstructionsBlock = """

                ### PROJECT-SPECIFIC INSTRUCTIONS (AGENTS.MD)
                \(agentInstructions)
                """
        }

        // Terminal tools are negotiated per client (clientCapabilities.terminal),
        // so only advertise them when the client actually supports them.
        let terminalToolsBlock = terminalToolsAvailable ? """
            ### TERMINAL & SHELL COMMANDS
            - You have terminal tools: run_command (one-shot: runs a command, waits for it to finish, and returns the exit status and output) plus terminal_create, terminal_output, terminal_wait_for_exit, terminal_kill, and terminal_release for long-running or background commands.
            - Prefer run_command for one-shot commands (git, swift, xcodebuild, scripts, ...). Use terminal_create with the other terminal tools when a command runs for a long time or you need to observe it while doing other work, and always terminal_release terminals you created when done.

            """ : ""

        // Web tools are useless on an offline machine; say so in the base
        // prompt for sessions that start while the network is down.
        let networkStatusBlock = online ? "" : """
            ### NETWORK STATUS
            The machine is currently offline. web_search and web_fetch will fail until the connection is restored. Do not attempt web tools; rely on local files and your existing knowledge, and let the user know the network is down.

            """

        // Skills use progressive disclosure: only the catalog (name +
        // description) goes into the prompt; the model loads the full
        // instructions on demand via the use_skill tool.
        let skillsBlock = skillCatalog(cwd).promptBlock()

        let template =
            systemPromptTemplates[client]
            ?? systemPromptTemplates[.generic(name: "unknown")]
            ?? ""

        return template
            .replacingOccurrences(of: "{{CWD}}", with: cwd)
            .replacingOccurrences(of: "{{TERMINAL_TOOLS}}", with: terminalToolsBlock)
            .replacingOccurrences(of: "{{NETWORK_STATUS}}", with: networkStatusBlock)
            .replacingOccurrences(of: "{{SKILLS}}", with: skillsBlock)
            .replacingOccurrences(of: "{{CUSTOM_INSTRUCTIONS}}", with: customInstructionsBlock)
    }

    // MARK: - Slot Mapping

    /// Maps a session to a stable server slot in `0..<count` using FNV-1a, so
    /// the same session always hits the same slot (and its cached context)
    /// across turns and process restarts. Returns `nil` when no slots are
    /// configured, letting the server pick one.
    private static func slotId(for sessionId: String, count: Int) -> Int? {
        guard count >= 1 else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in sessionId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }
}

// MARK: - Workspace Instructions

/// Loads project-specific instructions from an AGENTS.md file in `cwd`.
func loadWorkspaceInstructions(from cwd: String) -> String? {
    // Find the instructions file case-insensitively (agents.md, AGENTS.md, aGents.md, ...)
    guard let agentFileURL = findFile(named: "agents", extension: "md", in: cwd),
        let contents = try? String(contentsOf: agentFileURL, encoding: .utf8),
        !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        return nil
    }

    return contents.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Resolves a file in `directory` whose name and extension match case-insensitively.
func findFile(
    named name: String,
    extension ext: String,
    in directory: String
) -> URL? {
    let dirURL = URL(filePath: directory)
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }

    for entry in entries {
        // Compare the name and extension parts separately so that any casing works,
        // while still excluding directories that happen to share the file's name.
        let fileName = (entry as NSString).deletingPathExtension.lowercased()
        let fileExt = (entry as NSString).pathExtension.lowercased()
        guard fileName == name.lowercased(), fileExt == ext.lowercased() else { continue }

        let url = dirURL.appendingPathComponent(entry)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            return url
        }
    }
    return nil
}
