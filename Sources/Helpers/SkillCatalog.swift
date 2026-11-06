//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// SkillCatalog.swift
//

import Foundation
import Logger
import Stores

/// A single discovered skill: a directory containing a `SKILL.md` file with
/// YAML frontmatter (`name`, `description`) followed by markdown instructions.
public struct Skill: Sendable {
    public let name: String
    public let description: String
    /// Absolute path to the skill's `SKILL.md` file.
    public let path: String
    /// Absolute path to the skill's directory, which may hold sibling
    /// resources the skill references.
    public let directory: String

    public init(name: String, description: String, path: String, directory: String) {
        self.name = name
        self.description = description
        self.path = path
        self.directory = directory
    }
}

/// The parsed contents of a `SKILL.md` file: frontmatter metadata plus the
/// markdown body that follows the closing `---`.
public struct ParsedSkill: Equatable, Sendable {
    public let metadata: [String: String]
    public let body: String
}

/// Discovers skills from the standard locations and renders the compact
/// catalog block injected into the system prompt.
///
/// Skills use progressive disclosure: only each skill's name and description
/// go into the prompt; the model loads the full instructions on demand via
/// the `use_skill` tool.
public struct SkillCatalog: Sendable {
    /// Hard cap on the number of skills advertised in the prompt so a large
    /// directory tree cannot blow out the context window.
    public static let maxSkills = 50
    /// Descriptions are truncated in the prompt block to keep the catalog
    /// compact.
    public static let maxDescriptionLength = 200

    public let skills: [Skill]

    public init(skills: [Skill]) {
        self.skills = skills
    }

    /// Finds a skill by name, ignoring case.
    public func skill(named name: String) -> Skill? {
        skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Discovers skills for the working directory `cwd`.
    ///
    /// Precedence (highest first; the first definition of a name wins):
    /// 1. Project:  `<cwd>/.terrapincode/skills`
    /// 2. User:     `~/.terrapincode/skills`
    /// 3. Extra:    `extraDirectories` (`--skills-dir` / `AI_SKILLS_DIR`)
    /// 4. Bundled:  `bundledSkillFiles` (skill files shipped with the binary)
    public static func discover(
        cwd: String,
        extraDirectories: [String] = [],
        bundledSkillFiles: [URL] = [],
        userDirectory: URL = TerrapinPaths.userDirectory,
        logger: Loggable? = nil
    ) -> SkillCatalog {
        var roots: [String] = []
        if !cwd.isEmpty {
            roots.append((cwd as NSString).appendingPathComponent(".terrapincode/skills"))
        }
        roots.append(userDirectory.appendingPathComponent("skills").path)
        roots.append(contentsOf: extraDirectories)

        var byName: [String: Skill] = [:]
        var order: [String] = []
        func add(_ skill: Skill) {
            let key = skill.name.lowercased()
            if byName[key] == nil {
                byName[key] = skill
                order.append(key)
            }
        }
        for root in roots {
            for skill in scanDirectory(root, logger: logger) {
                add(skill)
            }
        }
        for file in bundledSkillFiles {
            if let skill = Self.skill(fromFile: file, logger: logger) {
                add(skill)
            }
        }

        return SkillCatalog(skills: order.prefix(Self.maxSkills).compactMap { byName[$0] })
    }

    /// Renders the compact catalog block for the system prompt. Returns an
    /// empty string when no skills are available so the prompt stays
    /// byte-identical to the no-skills template.
    public func promptBlock() -> String {
        guard !skills.isEmpty else { return "" }
        var lines = [
            "### AVAILABLE SKILLS",
            "Skills are reusable instruction packs for specific kinds of tasks. When the user's request matches a skill's description, call use_skill with that skill's name and follow the instructions it returns before proceeding. Do not call use_skill for tasks no skill describes.",
        ]
        for skill in skills {
            lines.append(
                "- \(skill.name) — \(String(skill.description.prefix(Self.maxDescriptionLength)))"
            )
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Discovery

    /// Scans one skill root: each immediate subdirectory that contains a
    /// `SKILL.md` (matched case-insensitively) is a skill.
    static func scanDirectory(_ root: String, logger: Loggable?) -> [Skill] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: root) else {
            return [] // The root does not exist yet; that is not an error.
        }

        var found: [Skill] = []
        for entry in entries.sorted() {
            let directory = (root as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            guard let skillFile = findSkillFile(in: directory) else { continue }
            guard let contents = try? String(contentsOf: skillFile, encoding: .utf8) else {
                logger?.debug("Skill: could not read \(skillFile.path); skipped")
                continue
            }
            if let skill = Self.makeSkill(
                file: skillFile,
                contents: contents,
                fallbackName: entry,
                directory: directory,
                logger: logger
            ) {
                found.append(skill)
            }
        }
        return found
    }

    /// Builds a skill from a standalone markdown file — the bundled layout,
    /// where the build system flattens each skill into a uniquely named
    /// `.md` file (e.g. `git-commit.md`) at the bundle root.
    static func skill(fromFile file: URL, logger: Loggable?) -> Skill? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
            logger?.debug("Skill: could not read \(file.path); skipped")
            return nil
        }
        return Self.makeSkill(
            file: file,
            contents: contents,
            fallbackName: file.deletingPathExtension().lastPathComponent,
            directory: file.deletingLastPathComponent().path,
            logger: logger
        )
    }

    /// Parses a skill file's contents into a `Skill`. The frontmatter
    /// `name` wins; `fallbackName` (the directory name for directory-based
    /// skills, the file's base name for standalone bundled files) is used
    /// when the frontmatter has no valid name.
    private static func makeSkill(
        file: URL,
        contents: String,
        fallbackName: String,
        directory: String,
        logger: Loggable?
    ) -> Skill? {
        guard let parsed = parseSkillFile(contents) else {
            logger?.debug("Skill: \(file.path) has no valid frontmatter; skipped")
            return nil
        }
        guard let description = parsed.metadata["description"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else {
            logger?.debug("Skill: \(file.path) is missing a 'description'; skipped")
            return nil
        }

        // Prefer the frontmatter name; fall back to the directory name.
        var name: String?
        if let raw = parsed.metadata["name"]?.trimmingCharacters(in: .whitespaces),
           isValidSkillName(raw)
        {
            name = raw
        }
        if name == nil, isValidSkillName(fallbackName) {
            name = fallbackName
        }
        guard let name else {
            logger?.debug("Skill: \(file.path) has an invalid name; skipped")
            return nil
        }

        return Skill(name: name, description: description, path: file.path, directory: directory)
    }

    /// Resolves the `SKILL.md` file inside a skill directory, matching the
    /// name and extension case-insensitively (like AGENTS.md handling).
    static func findSkillFile(in directory: String) -> URL? {
        let dirURL = URL(filePath: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        for entry in entries {
            let fileName = (entry as NSString).deletingPathExtension.lowercased()
            let fileExt = (entry as NSString).pathExtension.lowercased()
            guard fileName == "skill", fileExt == "md" else { continue }

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

    /// Skill names must be lowercase alphanumerics and hyphens so they are
    /// safe to pass as a single `use_skill` argument.
    public static func isValidSkillName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    // MARK: - SKILL.md Parsing

    /// Parses a `SKILL.md` file into frontmatter metadata and markdown body.
    /// Returns nil when the file does not start with a closed `---`
    /// frontmatter block. Only single-line `key: value` pairs are supported.
    public static func parseSkillFile(_ contents: String) -> ParsedSkill? {
        var lines = contents.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        // Strip a UTF-8 BOM and surrounding whitespace from the opening line.
        // whitespacesAndNewlines (not whitespaces) so CRLF line endings work.
        lines[0] = lines[0].trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{FEFF}").union(.whitespacesAndNewlines)
        )
        guard lines[0] == "---" else { return nil }

        var metadata: [String: String] = [:]
        var index = 1
        var closed = false
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." {
                closed = true
                break
            }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\""))
                       || (value.hasPrefix("'") && value.hasSuffix("'"))
                {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty {
                    metadata[key] = value
                }
            }
            index += 1
        }
        guard closed else { return nil }

        let body = lines[(index + 1)...]
            .joined(separator: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSkill(metadata: metadata, body: body)
    }
}
