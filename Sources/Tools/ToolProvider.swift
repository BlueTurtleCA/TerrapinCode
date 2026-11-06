//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ToolProvider.swift
//

import Foundation
import Stores

/// A source of tools the agent can call (Xcode MCP bridge, web tools, ...).
public protocol ToolProvider: Sendable {
    func definitions() async -> [ToolDefinition]
    func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async -> String

    /// One-time setup for a working directory, run before the agent loop so
    /// workspace-dependent tools are ready (e.g. opening the Xcode workspace
    /// and surfacing the user's access-approval prompt up front).
    func prepare(cwd: String) async
}

public extension ToolProvider {
    func prepare(cwd: String) async {}
}

/// Routes tool calls to the provider that owns the tool.
public struct ToolRegistry: Sendable {
    private let providers: ProviderBox

    /// Reference box around the provider list so providers can be registered
    /// after the registry is created (the Xcode MCP bridge is added lazily
    /// once the connecting client identifies itself as Xcode).
    private final class ProviderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [any ToolProvider]

        init(_ items: [any ToolProvider]) {
            self.items = items
        }

        func all() -> [any ToolProvider] {
            lock.withLock { items }
        }

        func add(_ provider: any ToolProvider) {
            lock.withLock { items.append(provider) }
        }
    }

    public init(_ providers: [any ToolProvider]) {
        self.providers = ProviderBox(providers)
    }

    /// Registers an additional provider.
    public func add(_ provider: any ToolProvider) {
        providers.add(provider)
    }

    public func definitions() async -> [ToolDefinition] {
        var all: [ToolDefinition] = []
        for provider in providers.all() {
            all.append(contentsOf: await provider.definitions())
        }
        return all
    }

    public func execute(
        name: String,
        argsJSON: String,
        cwd: String,
        sessionId: String,
        sendJSON: @escaping @Sendable ([String: Any]) -> Void
    ) async -> String {
        for provider in providers.all() {
            let providerTools = await provider.definitions()
            guard providerTools.contains(where: { $0.function.name == name }) else {
                continue
            }
            return await provider.execute(
                name: name,
                argsJSON: argsJSON,
                cwd: cwd,
                sessionId: sessionId,
                sendJSON: sendJSON
            )
        }
        return "Error: Unknown tool '\(name)'"
    }

    public func prepare(cwd: String) async {
        for provider in providers.all() {
            await provider.prepare(cwd: cwd)
        }
    }
}
