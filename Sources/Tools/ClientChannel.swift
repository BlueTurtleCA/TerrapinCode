//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ClientChannel.swift
//

import Foundation

/// A bidirectional JSON-RPC channel to the ACP client (e.g. Xcode).
///
/// The agent uses it to send requests that only the client can answer
/// (`fs/read_text_file`, `terminal/create`, ...). Client responses are
/// correlated back to the awaiting caller by request id.
public final class ClientChannel: @unchecked Sendable {
    /// The outcome of a request sent to the client.
    public enum ClientResponse: @unchecked Sendable {
        case result([String: Any])
        case error(String)
    }

    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [String: CheckedContinuation<ClientResponse, Never>] = [:]

        func insert(_ id: String, _ continuation: CheckedContinuation<ClientResponse, Never>) {
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }

        func remove(_ id: String) -> CheckedContinuation<ClientResponse, Never>? {
            lock.lock()
            defer { lock.unlock() }
            return continuations.removeValue(forKey: id)
        }
    }

    private let pending = Pending()
    private let lock = NSLock()
    private var sender: (@Sendable ([String: Any]) -> Void)?

    public init() {}

    /// Installs the transport used to deliver requests to the client.
    public func setSender(_ sender: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sender = sender
    }

    /// Routes an incoming client message to the awaiting request, if any.
    /// Returns true when the message answered a pending request.
    public func handleIncoming(_ json: [String: Any]) async -> Bool {
        guard json["method"] == nil else { return false }
        let id =
            (json["id"] as? String)
            ?? (json["id"] as? Int).map(String.init)
        guard let id, let continuation = pending.remove(id) else {
            return false
        }

        if let error = json["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "unknown client error"
            continuation.resume(returning: .error(message))
        } else {
            continuation.resume(
                returning: .result((json["result"] as? [String: Any]) ?? [:])
            )
        }
        return true
    }

    /// Sends a request to the client and awaits its response.
    public func request(
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 120
    ) async -> ClientResponse {
        let id = "agent-\(UUID().uuidString)"

        let sender = lock.withLock { self.sender }
        guard let sender else {
            return .error("Client channel is not connected")
        }

        sender([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])

        // Race the client's response against a timeout so a silent client
        // can never hang the agent.
        let response: ClientResponse? = await withTaskGroup(
            of: ClientResponse?.self
        ) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<ClientResponse, Never>) in
                    self.pending.insert(id, continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let response else {
            // Timeout: clean up the dangling continuation so it is resumed
            // exactly once, then report the failure.
            if let continuation = pending.remove(id) {
                continuation.resume(
                    returning: .error("Timed out waiting for the client to answer \(method)")
                )
            }
            return .error("Timed out waiting for the client to answer \(method)")
        }
        return response
    }
}
