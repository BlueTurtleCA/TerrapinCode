//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// SkillTools.swift
//

import Foundation
import Helpers
import Stores

/// Exposes the `use_skill` tool: the model calls it with a skill name from
/// the AVAILABLE SKILLS catalog in the system prompt and receives the
/// skill's full instructions.
public struct SkillTools: ToolProvider {
    /// Resolves the skill catalog for a working directory. Shared with the
    /// agent so the prompt catalog and the tool always agree.
    private let catalog: @Sendable (String) -> SkillCatalog

    public init(catalog: @escaping @Sendable (String) -> SkillCatalog) {
        self.catalog = catalog
    }

    // MARK: - Tool Definitions for OpenAI / AI Server Schema

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "use_skill",
                description: "Loads the full instructions of a skill from the AVAILABLE SKILLS list in your system prompt. Call it with the skill's name when the user's request matches a skill's description, and follow the returned instructions.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "name": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The name of the skill to load, exactly as listed in the AVAILABLE SKILLS section")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("name")])
                ]
            )
        )
    ]

    // MARK: - ToolProvider Conformance

    public func definitions() async -> [ToolDefinition] { Self.definitions }

    public func execute(name: String, argsJSON: String, cwd: String, sessionId: String, sendJSON: ([String: Any]) -> Void) async -> String {
        guard let data = argsJSON.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return "Error: Invalid JSON parameters supplied to \(name)"
        }
        guard let skillName = args["name"] as? String, !skillName.isEmpty else {
            return "Error: Missing 'name' parameter"
        }

        let callId = UUID().uuidString
        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": callId,
                    "title": "Loading skill '\(skillName)'",
                    "status": "in_progress",
                ]
            ]
        ])

        let result = Self.loadSkill(named: skillName, catalog: catalog(cwd))

        sendJSON([
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": sessionId,
                "update": [
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": callId,
                    "status": result.starts(with: "Error") ? "failed" : "completed"
                ]
            ]
        ])

        return result
    }

    // MARK: - Skill Loading

    /// Looks up `skillName` in the catalog and returns the skill's markdown
    /// body (frontmatter stripped) plus a pointer to its directory.
    static func loadSkill(named skillName: String, catalog: SkillCatalog) -> String {
        guard let skill = catalog.skill(named: skillName) else {
            let available = catalog.skills.map(\.name).joined(separator: ", ")
            return available.isEmpty
                ? "Error: No skills are available."
                : "Error: Unknown skill '\(skillName)'. Available skills: \(available)."
        }

        guard let contents = try? String(contentsOfFile: skill.path, encoding: .utf8) else {
            return "Error: Could not read skill file \(skill.path)"
        }
        guard let parsed = SkillCatalog.parseSkillFile(contents) else {
            return "Error: Skill file \(skill.path) has no valid frontmatter."
        }

        return """
        Skill '\(skill.name)' instructions:

        \(parsed.body)

        This skill lives in \(skill.directory); use read_file to open any sibling files it references.
        """
    }
}
