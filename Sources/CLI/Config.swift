//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Config.swift
//

import Foundation
import Stores

/// Runtime configuration sourced from CLI arguments (which take precedence)
/// and environment variables.
struct Config: Sendable {
    let serverURL: URL
    let model: String
    let contextWindowOverride: Int?
    /// Number of server-side context slots (llama.cpp `-np` / `n_parallel`).
    /// Sessions are pinned to a slot so the KV cache is reused across turns.
    let slots: Int
    /// When true, each request body sent to the AI server is written to
    /// ~/.terrapincode/logs/NNNN.json for prefix-stability debugging.
    let debugLog: Bool
    /// Client assumed when the connecting ACP client does not identify
    /// itself via `clientInfo` in the `initialize` request.
    let defaultClient: ClientKind
    /// Additional skill directories from `--skills-dir` / `AI_SKILLS_DIR`.
    let skillDirectories: [String]

    /// The OpenAI-compatible chat completions endpoint derived from the server base URL.
    var chatCompletionsURL: URL {
        serverURL.appendingPathComponent("v1/chat/completions")
    }

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments

        let serverURLString =
            argValue("--server", in: args)
            ?? env["AI_SERVER_URL"]
            ?? "http://localhost:8080"
        let model =
            argValue("--model", in: args)
            ?? env["AI_MODEL"]
            ?? "default"
        let contextWindowOverride =
            (argValue("--context-window", in: args)
                ?? env["AI_CONTEXT_WINDOW"])
            .flatMap(Int.init)
        let slots =
            (argValue("--slots", in: args)
                ?? env["AI_SLOTS"])
            .flatMap(Int.init) ?? 1
        let debugLog =
            (argValue("--debug-log", in: args)
                ?? env["AI_DEBUG_LOG"])
            .map {
                let v = $0.lowercased()
                return v == "1" || v == "true" || v == "yes"
            }
            ?? false
        let defaultClient =
            (argValue("--default-client", in: args)
                ?? env["AI_DEFAULT_CLIENT"])
            .map {
                $0.lowercased() == "generic"
                    ? ClientKind.generic(name: "unknown")
                    : ClientKind.xcode
            }
            ?? .xcode
        let skillDirectories = Self.skillDirectories(args: args, env: env)

        guard let serverURL = URL(string: serverURLString) else {
            fatalError("Invalid AI server URL: \(serverURLString)")
        }

        return Config(
            serverURL: serverURL,
            model: model,
            contextWindowOverride: contextWindowOverride,
            slots: slots,
            debugLog: debugLog,
            defaultClient: defaultClient,
            skillDirectories: skillDirectories
        )
    }

    private static func argValue(_ flag: String, in args: [String]) -> String? {
        guard
            let index = args.firstIndex(of: flag), index + 1 < args.count
        else { return nil }
        return args[index + 1]
    }

    /// Collects extra skill directories: repeatable `--skills-dir` flags plus
    /// the colon-separated `AI_SKILLS_DIR` environment variable.
    private static func skillDirectories(args: [String], env: [String: String]) -> [String] {
        var directories = argValues("--skills-dir", in: args)
        if let envValue = env["AI_SKILLS_DIR"] {
            directories.append(contentsOf: envValue.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    /// Returns every value of a repeatable `--flag value` CLI argument.
    private static func argValues(_ flag: String, in args: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < args.count {
            if args[index] == flag, index + 1 < args.count {
                values.append(args[index + 1])
                index += 1
            }
            index += 1
        }
        return values
    }
}
