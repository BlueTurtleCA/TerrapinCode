//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// SessionStore.swift
//

import Foundation
import Logger

public actor SessionStore {
    private var workingDirs: [String: String] = [:]
    private var histories: [String: [ChatMessage]] = [:]
    // Last observed network state per session, used to inject a note into
    // the conversation when the machine goes offline or the connection is
    // restored.
    private var networkStates: [String: Bool] = [:]
    // The context window the agent believes the model has, recorded per
    // session so the persisted file shows what compaction was tuned to.
    private var contextWindows: [String: Int] = [:]
    private let sessionsDirectory: URL
    private let logger: Loggable
    
    public init(logger: Loggable, sessionsDirectory: URL? = nil) {
        self.logger = logger
        self.sessionsDirectory = sessionsDirectory ?? TerrapinPaths.sessionsDirectory
    }

    /// Retention period for persisted sessions, in days. Mirrors Claude
    /// Code's cleanupPeriodDays (default 30): sessions not updated within
    /// this window are removed.
    public static let sessionRetentionDays = 30
    
    private func normalizePath(_ rawPath: String) -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip file:// URI scheme if present
        if path.hasPrefix("file://") {
            if let url = URL(string: path) {
                path = url.path
            } else {
                path = String(path.dropFirst(7))
            }
        }

        // 2. Expand tilde (~) paths
        path = (path as NSString).expandingTildeInPath

        // 3. Strip SPM metadata directories
        if path.hasSuffix("/.swiftpm/xcode") {
            path = String(path.dropLast("/.swiftpm/xcode".count))
        } else if let index = path.range(of: "/.swiftpm/")?.lowerBound {
            path = String(path[..<index])
        }

        // 4. Strip .xcodeproj / .xcworkspace bundle paths if passed as CWD
        if path.hasSuffix(".xcodeproj") || path.hasSuffix(".xcworkspace") {
            path = (path as NSString).deletingLastPathComponent
        }

        // 5. Standardize path and resolve symlinks (/var -> /private/var)
        let fileURL = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        path = fileURL.path

        // 6. Ensure NFC Unicode normalization for APFS filesystem compatibility
        return path.precomposedStringWithCanonicalMapping
    }
    
    // Set CWD when session/new or prompt comes in
    public func setCWD(_ cwd: String, for sessionId: String) {
        workingDirs[sessionId] = normalizePath(cwd)
        persist(sessionId)
    }
    
    // Retrieve CWD for a given session
    public func getCWD(for sessionId: String) -> String? {
        return workingDirs[sessionId]
    }
    
    // Last observed network state for a session (nil when never observed).
    public func networkState(for sessionId: String) -> Bool? {
        return networkStates[sessionId]
    }
    
    // Records the session's network state so the next turn can detect a
    // transition and notify the model.
    public func setNetworkState(_ online: Bool, for sessionId: String) {
        networkStates[sessionId] = online
        persist(sessionId)
    }
    
    // The context window the agent believes the model has, so the persisted
    // session records the basis for its compaction threshold.
    public func contextWindow(for sessionId: String) -> Int? {
        return contextWindows[sessionId]
    }
    
    public func setContextWindow(_ window: Int, for sessionId: String) {
        contextWindows[sessionId] = window
        persist(sessionId)
    }
    
    // Get chat history or fallback to standard system prompt
    public func getHistory(for sessionId: String, defaultSystemPrompt: String) -> [ChatMessage] {
        return histories[sessionId] ?? [
            ChatMessage(role: "system", content: defaultSystemPrompt)
        ]
    }
    
    // Save updated conversation history
    public func saveHistory(_ history: [ChatMessage], for sessionId: String) {
        histories[sessionId] = history
        persist(sessionId)
    }

    /// Restores a session from disk (used by session/load). Returns true when
    /// the session was loaded into memory, either from disk or because it is
    /// already active in this process.
    public func loadSession(for sessionId: String) -> Bool {
        // Already active in this process (e.g. created via session/new earlier).
        if workingDirs[sessionId] != nil || histories[sessionId] != nil {
            return true
        }
        guard
            let data = try? Data(contentsOf: fileURL(for: sessionId)),
            let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
        else {
            return false
        }
        if let cwd = record.cwd {
            workingDirs[sessionId] = cwd
        }
        if let state = record.networkState {
            networkStates[sessionId] = state
        }
        if let window = record.contextWindow {
            contextWindows[sessionId] = window
        }
        histories[sessionId] = record.history
        return true
    }

    /// Raw stored history for a session, or nil when the session has none.
    public func history(for sessionId: String) -> [ChatMessage]? {
        return histories[sessionId]
    }

    /// Removes session files not modified within the retention period.
    /// Called once per process start so stale sessions don't accumulate
    /// (the same startup sweep Claude Code performs).
    public func cleanupStaleSessions() {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return // No sessions directory yet; nothing to clean.
        }
        let cutoff = Date().addingTimeInterval(
            -Double(Self.sessionRetentionDays) * 86_400
        )
        for url in entries where url.pathExtension == "json" {
            let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
                logger.debug("Removed stale session file \(url.lastPathComponent)")
            }
        }
    }

    /// Deletes a session's persisted state (used by session/delete). Silently
    /// succeeds when the session does not exist, per the ACP spec.
    public func deleteSession(for sessionId: String) {
        workingDirs[sessionId] = nil
        histories[sessionId] = nil
        networkStates[sessionId] = nil
        contextWindows[sessionId] = nil
        do {
            try FileManager.default.removeItem(at: fileURL(for: sessionId))
        } catch let error as NSError where
            error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError
        {
            // Expected for unknown or already-deleted sessions.
        } catch {
            logger.debug("Failed to delete session \(sessionId): \(error)")
        }
    }

    // MARK: - Persistence

    /// On-disk representation of a session: working directory + chat history.
    private struct SessionRecord: Codable {
        var cwd: String?
        var history: [ChatMessage]
        var networkState: Bool?
        var contextWindow: Int?
    }

    /// File for a session. Session IDs are normally UUIDs, but clients may
    /// send arbitrary strings (e.g. "debug1"), so keep the file inside the
    /// sessions directory no matter what arrives.
    private func fileURL(for sessionId: String) -> URL {
        let safeName = sessionId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return sessionsDirectory.appendingPathComponent("\(safeName).json")
    }

    /// Writes the session's current state to disk so a restarted process can
    /// restore it via session/load.
    private func persist(_ sessionId: String) {
        let record = SessionRecord(
            cwd: workingDirs[sessionId],
            history: histories[sessionId] ?? [],
            networkState: networkStates[sessionId],
            contextWindow: contextWindows[sessionId]
        )
        do {
            try FileManager.default.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL(for: sessionId), options: .atomic)
        } catch {
            logger.debug("Failed to persist session \(sessionId): \(error)")
        }
    }
}
