//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ClientKind.swift
//

import Foundation

/// Identifies the ACP client connected to the server so the agent can adapt
/// its system prompt and toolset (e.g. Xcode MCP tools only make sense when
/// Xcode is driving the session).
public enum ClientKind: Sendable, Hashable {
    /// Xcode 27, which drives the native `xcrun mcpbridge` toolset.
    case xcode
    /// Any other ACP client (VS Code, Zed, JetBrains, ...).
    case generic(name: String)

    /// Detects the connecting client from the `initialize` request's
    /// `clientInfo` field, falling back to Xcode-specific environment
    /// variables, then to `fallback`.
    public static func detect(
        clientInfo: [String: Any]?,
        environment: [String: String],
        fallback: ClientKind = .xcode
    ) -> ClientKind {
        let name = clientInfo?["name"] as? String ?? ""
        let title = clientInfo?["title"] as? String ?? ""
        let identity = (name + " " + title).lowercased()

        if identity.contains("xcode") {
            return .xcode
        }

        // Xcode injects XCODE_* variables into the agent process environment.
        if environment.keys.contains(where: { $0.uppercased().contains("XCODE") }) {
            return .xcode
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return fallback }
        return .generic(name: trimmedName)
    }
}
