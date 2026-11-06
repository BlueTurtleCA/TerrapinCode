//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// XcodeMCPBridgeClient.swift
//

import Foundation
import Logger
import Stores

public actor XcodeMCPBridgeClient: ToolProvider {
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var logger: Loggable

    private var activeTabIdentifier: String?
    private var activeWorkspaceIdentifier: String?
    private var tools: [ToolDefinition] = []
    private var openedWorkspacePath: String?
    private var started = false
    // When the agent is not approved, re-opening the workspace re-asks the
    // user for approval. This timestamp throttles those re-opens so a batch
    // of failing tool calls in one turn does not fire a prompt per call.
    private var lastApprovalReopen: Date?
    // When true, every mcpbridge tool call (name, args, raw response) is
    // appended to ~/.terrapincode/logs/mcp_bridge.log for inspection.
    private let debugLog: Bool
    
    /// True once `start()` has spawned the mcpbridge process.
    public var isStarted: Bool { started }

    public func definitions() async -> [ToolDefinition] { tools }

    // File tools (XcodeMV, XcodeRM, XcodeLS) are intentionally not exposed:
    // the wrapper tools (move_file, delete_file, list_directory) prefer the
    // bridge internally and fall back to local operations when it fails.
    private let allowedMCPBridgeTools: Set<String> = [
        "BuildProject",
        "GetBuildLog",
        "XcodeListNavigatorIssues",
        "XcodeRefreshCodeIssuesInFile",
        "RunSomeTests",
        "RunAllTests",
        "RunCodeSnippet",
        "RenderPreview",
        "DocumentationSearch",
        "XcodeOpenWorkspace"
    ]
    
    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void)
        async -> String
    {
        let callId = "call_" + UUID().uuidString
        let (kind, title) = categorizeMCPTool(name: name, argsJSON: argsJSON)
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "name": name,
                    "title": title,
                    "kind": kind,
                    "status": "in_progress"
                ]
            ]
        ])
        
        let result = await callTool(name: name, argsJSON: argsJSON, cwd: cwd)
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": Self.isBridgeError(result) ? "failed" : "completed"
                ]
            ]
        ])
        
        return result
    }

    /// Opens the Xcode workspace for `cwd` before the agent loop so that
    /// workspace-dependent tools (XcodeRead, ...) work on the first call and
    /// the user's access-approval prompt appears up front instead of after a
    /// refused read. No-op if this workspace is already open.
    public func prepare(cwd: String) async {
        guard !cwd.isEmpty, openedWorkspacePath != cwd else { return }

        let args: [String: Any] = ["path": cwd]
        let argsJSON =
            (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let result = await callTool(
            name: "XcodeOpenWorkspace",
            argsJSON: argsJSON,
            cwd: cwd
        )
        logger.debug("XcodeOpenWorkspace(\(cwd)): \(result)")

        // The bridge identifies workspaces by an opaque identifier (e.g.
        // "workspace-LR49lofe9w"), not by path, so capture it from the open
        // response and fall back to listing workspaces if it is missing.
        // Only mark the workspace as opened once an identifier is resolved;
        // otherwise the next turn retries the open.
        if let identifier = parseWorkspaceIdentifier(from: result) {
            activeWorkspaceIdentifier = identifier
            openedWorkspacePath = cwd
        } else if let resolved = await resolveWorkspaceIdentifier(matchingCWD: cwd) {
            activeWorkspaceIdentifier = resolved
            openedWorkspacePath = cwd
        }
    }

    public init(_ logger: Loggable, debugLog: Bool = false) {
        self.logger = logger
        self.debugLog = debugLog
    }

    /// Spawns `xcrun mcpbridge` using environment variables passed by Xcode ACP
    public func start(env: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["mcpbridge"]

        // 1. Inject Xcode PID and Session ID into process environment
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()

        process.standardInput = inPipe
        process.standardOutput = outPipe

        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.process = process

        try process.run()
        started = true

        // 2. Step 1 of MCP Handshake: Send initialize request
        let initRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "TerrapinCode", "version": "1.0.0"],
            ],
        ]
        _ = try? sendRPC(initRequest)

        // 3. Step 2 of MCP Handshake: Send mandatory notifications/initialized
        let initializedNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        try? sendNotification(initializedNotification)
    }

    /// Fetches all dynamic workspace tools provided by Xcode's mcpbridge
    @discardableResult
    public func fetchTools() async -> [ToolDefinition] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]

        guard let response = try? sendRPC(request),
            let result = response["result"] as? [String: Any],
            let toolsArray = result["tools"] as? [[String: Any]]
        else {
            return []
        }

        var tools: [ToolDefinition] = []
        for toolDict in toolsArray {
            guard let name = toolDict["name"] as? String,
                allowedMCPBridgeTools.contains(name),
                let description = toolDict["description"] as? String,
                let inputSchema = toolDict["inputSchema"] as? [String: Any]
            else { continue }

            if let schemaData = try? JSONSerialization.data(
                withJSONObject: inputSchema
            ),
                let wrappedSchema = try? JSONDecoder().decode(
                    [String: AnySendable].self,
                    from: schemaData
                )
            {

                let definition = ToolDefinition(
                    function: FunctionDefinition(
                        name: name,
                        description: description,
                        parameters: wrappedSchema
                    )
                )
                tools.append(definition)
            }
        }

        self.tools = tools
        return tools
    }

    /// Executes a tool call in Xcode via mcpbridge, with automatic tabIdentifier injection
    public func callTool(name: String, argsJSON: String, cwd: String)
        async -> String
    {
        let result = await performToolCall(name: name, argsJSON: argsJSON, cwd: cwd)
        if debugLog {
            Self.appendBridgeDebugLog(name: name, argsJSON: argsJSON, result: result)
        }
        return result
    }

    /// The actual mcpbridge round-trip for a tool call, including the
    /// tabIdentifier / workspaceIdentifier resolve-and-retry logic. Split out
    /// from callTool so every response can be captured for the debug log.
    private func performToolCall(name: String, argsJSON: String, cwd: String)
        async -> String
    {
        let argsData = argsJSON.data(using: .utf8) ?? Data()
        var argsDict =
            (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any])
            ?? [:]

        // 1. Auto-inject cached tabIdentifier if available and missing from LLM arguments
        if argsDict["tabIdentifier"] == nil, let cachedTab = activeTabIdentifier
        {
            argsDict["tabIdentifier"] = cachedTab
        }

        // 2. Auto-inject the cached workspace identifier if missing, since Xcode
        //    workspace tools require it to resolve the target project. When no
        //    identifier is cached, omit the field: the bridge's error then drives
        //    the resolve-and-retry below instead of injecting a raw path the
        //    bridge would reject as unknown.
        if argsDict["workspaceIdentifier"] == nil,
            let cachedWorkspace = activeWorkspaceIdentifier
        {
            argsDict["workspaceIdentifier"] = cachedWorkspace
        }
                
        // Send initial RPC tool call request
        let response = sendToolRPC(name: name, argsDict: argsDict)
        let outputText = parseToolOutput(response: response, name: name)

        // Cache the identifier returned by an explicit open (whether triggered
        // by prepare or by the model calling XcodeOpenWorkspace) so subsequent
        // calls inject it without re-resolving.
        if name == "XcodeOpenWorkspace",
            let identifier = parseWorkspaceIdentifier(from: outputText)
        {
            activeWorkspaceIdentifier = identifier
        }

        // 3. Check if mcpbridge threw a tabIdentifier required error
        if outputText.contains("tabIdentifier is required for this action") {
            if let matchedTab = parseTabIdentifier(
                from: outputText,
                matchingCWD: cwd
            ) {
                // Cache the matched tab for future calls
                self.activeTabIdentifier = matchedTab

                // Re-inject tabIdentifier and retry immediately
                argsDict["tabIdentifier"] = matchedTab
                let retryResponse = sendToolRPC(name: name, argsDict: argsDict)
                return parseToolOutput(response: retryResponse, name: name)
            }
        }

        // 4. If the bridge rejects the injected workspace identifier (or none
        //    was available), resolve the correct one from XcodeListWorkspaces
        //    and retry once. The bridge's message is lowercase ("unknown
        //    workspace identifier"), so compare case-insensitively.
        let loweredOutput = outputText.lowercased()
        if name != "XcodeListWorkspaces",
            loweredOutput.contains("unknown workspace identifier")
                || loweredOutput.contains("workspaceidentifier is required")
        {
            if let resolved = await resolveWorkspaceIdentifier(matchingCWD: cwd) {
                activeWorkspaceIdentifier = resolved
                argsDict["workspaceIdentifier"] = resolved
                let retryResponse = sendToolRPC(name: name, argsDict: argsDict)
                return parseToolOutput(response: retryResponse, name: name)
            }
        }

        // 5. If Xcode reports the agent isn't approved to use its tools yet,
        //    re-open the workspace: opening a project is what asks the user
        //    to approve the agent, so this re-surfaces the approval prompt.
        //    The cached identifiers belong to the pre-approval session and
        //    are stale, so drop them and let the open response refresh them.
        //    Retry the call once; if the user declines again the retried
        //    result (still the approval message) is returned as-is.
        if name != "XcodeOpenWorkspace", Self.isNotApproved(outputText) {
            let cooldownElapsed = lastApprovalReopen.map { Date().timeIntervalSince($0) >= 30 } ?? true
            if cooldownElapsed {
                lastApprovalReopen = Date()
                activeWorkspaceIdentifier = nil
                openedWorkspacePath = nil

                let openArgs: [String: Any] = ["path": cwd]
                let openArgsJSON =
                    (try? JSONSerialization.data(withJSONObject: openArgs))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let openResult = await callTool(
                    name: "XcodeOpenWorkspace",
                    argsJSON: openArgsJSON,
                    cwd: cwd
                )
                logger.debug("Approval re-open XcodeOpenWorkspace(\(cwd)): \(openResult)")

                // callTool caches the identifier from the open response;
                // inject the fresh one so the retry targets the re-opened
                // workspace.
                if let identifier = activeWorkspaceIdentifier {
                    argsDict["workspaceIdentifier"] = identifier
                }
                let retryResponse = sendToolRPC(name: name, argsDict: argsDict)
                return parseToolOutput(response: retryResponse, name: name)
            }
        }

        return outputText
    }

    // MARK: - Helper Methods

    private func sendToolRPC(name: String, argsDict: [String: Any]) -> [String:
        Any]?
    {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1000...9999),
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": argsDict,
            ],
        ]
        return try? sendRPC(request)
    }

    private func parseToolOutput(response: [String: Any]?, name: String)
        -> String
    {
        guard let response else {
            return "Error: No response from Xcode mcpbridge"
        }

        if let error = response["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return "Error executing tool '\(name)': \(message)"
        }

        guard let result = response["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]]
        else {
            return "Error: Invalid content returned by tool '\(name)'"
        }

        let lines = content.compactMap { $0["text"] as? String }
        return lines.joined(separator: "\n")
    }

    /// Appends a record for a bridge tool call to ~/.terrapincode/logs/
    /// mcp_bridge.log so the raw mcpbridge response for every Xcode MCP tool
    /// operation can be inspected. Only called when debugLog is enabled.
    private static func appendBridgeDebugLog(name: String, argsJSON: String, result: String) {
        let directory = TerrapinPaths.logsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("mcp_bridge.log")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let flattenedArgs = argsJSON.replacingOccurrences(of: "\n", with: " ")
        let flattenedResult = result.replacingOccurrences(of: "\n", with: " \\n ")
        let record = """
        [\(timestamp)] \(name)
          args: \(flattenedArgs)
          result: \(flattenedResult)

        """

        guard let data = record.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Returns true when a mcpbridge tool response represents an error.
    ///
    /// mcpbridge reports tool errors as a JSON object with a `"type":"error"`
    /// field (e.g. `{"data":"Missing required parameter 'sourcePath'…",
    /// "type":"error"}`), which does NOT start with `"Error"`. A naive
    /// `starts(with: "Error")` check therefore misclassifies these as success.
    /// This covers both the RPC-level error strings this client produces
    /// (which do start with "Error") and the JSON error payloads.
    static func isBridgeError(_ result: String) -> Bool {
        if result.starts(with: "Error") { return true }
        if isNotApproved(result) { return true }
        guard
            let data = result.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["type"] as? String) == "error"
    }

    /// True when mcpbridge reports that the agent has not been approved to
    /// use Xcode's tools yet. Xcode returns this as ordinary tool-result text
    /// (not a JSON-RPC error), so without this check callers would treat a
    /// refused write or delete as a success.
    static func isNotApproved(_ result: String) -> Bool {
        result.lowercased().contains("isn't approved to use xcode's tools")
    }

    /// Matches open window tabs directly against the pre-normalized `cwd`
    private func parseTabIdentifier(from errorText: String, matchingCWD: String)
        -> String?
    {
        let lines = errorText.components(separatedBy: .newlines)
        var matches: [(tab: String, path: String)] = []

        for line in lines
        where line.contains("tabIdentifier:") && line.contains("workspacePath:")
        {
            let parts = line.components(separatedBy: ",")
            var foundTab = ""
            var foundPath = ""

            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("tabIdentifier:") {
                    foundTab = trimmed.replacingOccurrences(of: "*", with: "")
                        .replacingOccurrences(of: "tabIdentifier:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                } else if trimmed.contains("workspacePath:") {
                    foundPath = trimmed.replacingOccurrences(
                        of: "workspacePath:",
                        with: ""
                    )
                    .trimmingCharacters(in: .whitespaces)
                }
            }

            if !foundTab.isEmpty && !foundPath.isEmpty {
                matches.append((tab: foundTab, path: foundPath))
            }
        }

        // Match against pre-normalized working directory
        if let match = matches.first(where: {
            $0.path == matchingCWD || matchingCWD.hasPrefix($0.path)
                || $0.path.hasPrefix(matchingCWD)
        }) {
            return match.tab
        }

        return matches.first?.tab
    }

    /// Extracts the `workspaceIdentifier` field from an XcodeOpenWorkspace
    /// response, e.g. `{"workspaceIdentifier":"workspace-LR49lofe9w", ...}`.
    /// Tries a strict whole-text JSON parse first, then falls back to scanning
    /// for the field so responses with surrounding prose still resolve.
    private func parseWorkspaceIdentifier(from text: String) -> String? {
        if let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let identifier = Self.cleanIdentifier(json["workspaceIdentifier"] as? String)
        {
            return identifier
        }

        guard let match = text.firstMatch(
            of: /"workspaceIdentifier"\s*:\s*"([^"]+)"/
        ) else { return nil }
        return Self.cleanIdentifier(String(match.1))
    }

    /// Strips the `*` marker Xcode uses to flag the active workspace or tab
    /// in list output, plus surrounding whitespace. Returns nil when nothing
    /// usable remains.
    private static func cleanIdentifier(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Lists open workspaces and returns the identifier whose `workspacePath`
    /// matches `cwd`. When a project appears as both a workspace and a window
    /// tab, the workspace-level identifier is preferred.
    private func resolveWorkspaceIdentifier(matchingCWD cwd: String) async -> String? {
        let result = await callTool(name: "XcodeListWorkspaces", argsJSON: "{}", cwd: cwd)
        logger.debug("XcodeListWorkspaces: \(result)")

        var fallback: String?
        for line in result.components(separatedBy: .newlines)
        where line.contains("workspaceIdentifier:") && line.contains("workspacePath:")
        {
            var identifier: String?
            var path = ""
            for part in line.components(separatedBy: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("workspaceIdentifier:") {
                    // Xcode marks the active entry with a `*` (e.g.
                    // "workspaceIdentifier: *  windowtab-XXX"); the marker is
                    // not part of the identifier and the bridge rejects it.
                    identifier = Self.cleanIdentifier(
                        trimmed.replacingOccurrences(of: "workspaceIdentifier:", with: "")
                    )
                } else if trimmed.contains("workspacePath:") {
                    path = trimmed
                        .replacingOccurrences(of: "workspacePath:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            guard let identifier, !path.isEmpty else { continue }
            if path == cwd || cwd.hasPrefix(path) || path.hasPrefix(cwd) {
                if identifier.hasPrefix("workspace-") {
                    return identifier
                }
                fallback = identifier
            }
        }
        return fallback
    }

    // MARK: - Low-Level Line-Buffered JSON-RPC Transport

    private func sendNotification(_ json: [String: Any]) throws {
        guard let inputPipe else { return }
        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)  // Newline delimiter
        inputPipe.fileHandleForWriting.write(data)
    }

    private func sendRPC(_ json: [String: Any]) throws -> [String: Any]? {
        guard let inputPipe, let outputPipe else { return nil }

        var data = try JSONSerialization.data(withJSONObject: json)
        data.append(0x0A)
        inputPipe.fileHandleForWriting.write(data)

        return readNextJSONLine(from: outputPipe)
    }

    private func readNextJSONLine(from pipe: Pipe) -> [String: Any]? {
        let fileHandle = pipe.fileHandleForReading

        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(..<buffer.index(after: newlineIndex))

                if lineData.isEmpty { continue }

                if let json = try? JSONSerialization.jsonObject(
                    with: Data(lineData)
                ) as? [String: Any] {
                    return json
                }
            }

            let newData = fileHandle.availableData
            if newData.isEmpty { break }
            buffer.append(newData)
        }

        return nil
    }

    private func categorizeMCPTool(name: String, argsJSON: String) -> (kind: String, title: String) {
        switch name {
        case "BuildProject":
            return ("execute", name)
        case "XcodeClean":
            return ("execute", name)
        case "RunSomeTests", "RunAllTests":
            return ("execute", name)
        case "RunCodeSnippet":
            return ("execute", name)
        case "DocumentationSearch":
            return ("other", "Searching Apple Documentation")
        case "GetBuildLog", "XcodeListNavigatorIssues":
            return ("other", "Fetching Xcode Diagnostics with \(name)")
        case "XcodeRefreshCodeIssuesInFile":
            return ("other", "Refreshing Code Issues")
        case "RenderPreview":
            return ("other", "Rendering SwiftUI Preview")
        default:
            return ("execute", name)
        }
    }
    
    deinit {
        process?.terminate()
    }
}
