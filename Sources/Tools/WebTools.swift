//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// WebTools.swift
//

import Foundation
import Helpers
import Stores

public struct WebTools: ToolProvider {
    private let monitor: NetworkMonitor

    public init(monitor: NetworkMonitor = .shared) {
        self.monitor = monitor
    }

    // MARK: - Tool Definitions for OpenAI / AI Server Schema

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "web_fetch",
                description: "Fetches and converts the text content of any HTTP/HTTPS URL into readable plain text. Content larger than ~30KB is saved to .terrapincode/web/ in the workspace and a preview is returned; use grep_file or read_file on the saved path to inspect the full content.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "url": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The target HTTP/HTTPS URL to read")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("url")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "web_search",
                description: "Searches the live web for real-time information, Swift documentation, or code solutions.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "query": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The web search query string")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("query")])
                ]
            )
        )
    ]
    
    // MARK: - ToolProvider Conformance

    public func definitions() async -> [ToolDefinition] { Self.definitions }

    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Error: Invalid JSON parameters supplied to \(name)"
        }
        
        let callId = UUID().uuidString
        
        let info = args["url"] != nil ? args["url"] as! String : args["query"] as! String
        let title = name == "web_search" ? "Searching for '\(info)'" : "Fetching URL \(info)"
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "title": title,
                    "status": "in_progress",
                ]
            ]
        ])
        
        // Fail fast when the machine has no network path (e.g. Wi-Fi shut
        // off) so the model gets an actionable message instead of a timeout.
        let response: String
        if !(await monitor.isOnline) {
            response = "Error: No network connection available. \(name) cannot run until the network is restored. Do not retry this tool; tell the user the machine is offline and continue with local tools."
        } else {
            response = await Self.execute(name: name, argsJSON: argsJSON, cwd: cwd)
        }
        
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": response.starts(with: "Error") ? "failed" : "completed"
                ]
            ]
        ])
        
        return response
    }

    // MARK: - Execution Dispatcher

    /// Maximum characters returned inline. Larger fetches are saved to the
    /// workspace so the model can grep/read them instead of flooding context.
    private static let inlineLimit = 30_000
    private static let previewLimit = 2_000

    public static func execute(name: String, argsJSON: String, cwd: String) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "Error: Invalid JSON parameters supplied to \(name)"
        }
        
        switch name {
        case "web_fetch":
            guard let urlString = args["url"] as? String else { return "Error: Missing 'url' parameter" }
            return await fetchURL(urlString, cwd: cwd)
            
        case "web_search":
            guard let query = args["query"] as? String else { return "Error: Missing 'query' parameter" }
            return await searchWeb(query)
            
        default:
            return "Error: Unknown tool '\(name)'"
        }
    }
    
    // MARK: - Core Web Implementations
    
    /// Fetches HTML from a web page and strips tags/scripts into plain text.
    /// Content larger than `inlineLimit` is saved under `.terrapincode/web/`
    /// in the workspace and a pointer + preview is returned instead, so the
    /// model can grep_file/read_file the full content on demand.
    private static func fetchURL(_ urlString: String, cwd: String) async -> String {
        guard let url = URL(string: urlString) else {
            return "Error: Invalid URL string '\(urlString)'"
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return "Error: Server returned non-200 HTTP status."
            }
            
            guard let htmlString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                return "Error: Failed to decode web page data."
            }
            
            let text = cleanHTML(htmlString)
            
            guard text.count > inlineLimit, !cwd.isEmpty else { return text }
            
            guard let savedPath = saveToWorkspace(text: text, urlString: urlString, cwd: cwd) else {
                return "Warning: could not save large content to workspace; showing first \(inlineLimit) of \(text.count) characters.\n\n"
                    + String(text.prefix(inlineLimit))
            }
            
            let preview = String(text.prefix(previewLimit))
            return """
            Content too large for inline display (\(text.count) characters).
            Full content saved to: \(savedPath)
            Use grep_file or read_file on that path to inspect the full content, and delete_file it when done.

            Preview (first \(previewLimit) characters):
            \(preview)
            """
        } catch {
            return "Error fetching URL: \(error.localizedDescription)"
        }
    }
    
    /// Writes `text` to `.terrapincode/web/` in the workspace using a
    /// deterministic name derived from the URL, so re-fetching the same URL
    /// overwrites the same file. Returns the workspace-relative path.
    private static func saveToWorkspace(text: String, urlString: String, cwd: String) -> String? {
        let directory = TerrapinPaths.webCacheDirectory(in: cwd)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch { return nil }
        
        let url = URL(string: urlString)
        var base = url?.host ?? "web"
        if let path = url?.path, !path.isEmpty, path != "/" { base += path }
        base = base.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        base = String(base.prefix(60))
        
        // FNV-1a hash of the URL so distinct URLs never collide.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in urlString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        
        let ext = url?.pathExtension ?? ""
        let fileName = "\(base)-\(String(hash, radix: 16)).\(ext.isEmpty ? "txt" : ext)"
        let filePath = (directory as NSString).appendingPathComponent(fileName)
        
        do {
            try text.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch { return nil }
        
        // Workspace-relative path so the model can pass it straight to
        // grep_file/read_file.
        var relative = filePath
        if relative.hasPrefix(cwd) {
            relative = String(relative.dropFirst(cwd.count))
        }
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }
    
    /// Executes web search using Tavily API (or falls back to DuckDuckGo HTML)
    private static func searchWeb(_ query: String) async -> String {
        // Option A: Tavily API Search (If API key exists in environment)
        if let apiKey = ProcessInfo.processInfo.environment["TAVILY_API_KEY"], !apiKey.isEmpty {
            return await searchTavily(query: query, apiKey: apiKey)
        }
        
        // Option B: DuckDuckGo Fallback
        return await searchDuckDuckGo(query: query)
    }
    
    private static func searchTavily(query: String, apiKey: String) async -> String {
        guard let url = URL(string: "https://api.tavily.com/search") else { return "Error creating search URL" }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 5
        ]
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return "Error serializing request" }
        request.httpBody = httpBody
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return "No results found."
            }
            
            return results.compactMap { dict in
                guard let title = dict["title"] as? String,
                      let link = dict["url"] as? String,
                      let content = dict["content"] as? String else { return nil }
                return "### \(title)\nURL: \(link)\n\(content)\n"
            }.joined(separator: "\n---\n")
        } catch {
            return "Search error: \(error.localizedDescription)"
        }
    }
    
    private static func searchDuckDuckGo(query: String) async -> String {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)") else {
            return "Error constructing query URL."
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return "Failed to read search response." }
            let text = cleanHTML(html)
            return String(text.prefix(3000)) // Cap response size
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }
    
    // Helper to strip CSS, JavaScript, and HTML tags into clean text
    private static func cleanHTML(_ html: String) -> String {
        var text = html
        // 1. Remove script & style tags
        text = text.replacingOccurrences(of: "(?s)<script.*?>.*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<style.*?>.*?</style>", with: "", options: .regularExpression)
        // 2. Strip standard HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        // 3. Clean up blank space & newlines
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
