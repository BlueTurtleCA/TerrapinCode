//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Paths.swift
//

import Foundation

/// Centralized on-disk locations for TerrapinCode.
///
/// User-level state lives under `~/.terrapincode/`; workspace-level scratch
/// lives under `./.terrapincode/` in the session's working directory.
public enum TerrapinPaths {
    /// User-level root: `~/.terrapincode`.
    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".terrapincode", isDirectory: true)
    }

    /// Persisted session state: `~/.terrapincode/sessions`.
    public static var sessionsDirectory: URL {
        userDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// LLM request debug logs: `~/.terrapincode/logs`.
    public static var logsDirectory: URL {
        userDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    /// Workspace-level scratch directory name (web fetch cache, ...).
    public static let workspaceDirectoryName = ".terrapincode"

    /// Workspace-level web fetch cache: `./.terrapincode/web` under `cwd`.
    public static func webCacheDirectory(in cwd: String) -> String {
        (cwd as NSString).appendingPathComponent(
            workspaceDirectoryName + "/web"
        )
    }
}
