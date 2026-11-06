//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// SkillCatalogTests.swift
//

import Foundation
import Testing
import Stores

@testable import Helpers

// MARK: - Shared helpers

/// A temporary directory removed on deinit.
private final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-catalog-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes a skill directory with a standard SKILL.md under `root`.
private func writeSkill(
    in root: URL,
    name: String,
    description: String,
    body: String = "Do the thing.",
    fileName: String = "SKILL.md"
) throws {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let contents = """
    ---
    name: \(name)
    description: \(description)
    ---
    \(body)
    """
    try contents.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
}

/// Writes a standalone bundled skill file (`<name>.md`, the flattened
/// bundle layout) under `root` and returns its URL.
private func writeBundledSkill(
    in root: URL,
    name: String,
    description: String,
    body: String = "Do the thing."
) throws -> URL {
    let url = root.appendingPathComponent("\(name).md")
    let contents = """
    ---
    name: \(name)
    description: \(description)
    ---
    \(body)
    """
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Appends a subpath to a temp directory, creating the directory.
private func skillRoot(_ temp: TempDir, _ subpath: String) throws -> URL {
    let url = temp.url.appendingPathComponent(subpath, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - parseSkillFile

@Suite("parseSkillFile")
struct ParseSkillFileTests {
    @Test func parsesFrontmatterAndBody() {
        let contents = """
        ---
        name: my-skill
        description: Does the thing.
        ---
        # My Skill
        Step one.
        """
        let result = SkillCatalog.parseSkillFile(contents)
        #expect(result?.metadata["name"] == "my-skill")
        #expect(result?.metadata["description"] == "Does the thing.")
        #expect(result?.body == "# My Skill\nStep one.")
    }

    @Test func stripsSurroundingQuotes() {
        let contents = """
        ---
        name: "quoted-name"
        description: 'Quoted description.'
        ---
        Body
        """
        let result = SkillCatalog.parseSkillFile(contents)
        #expect(result?.metadata["name"] == "quoted-name")
        #expect(result?.metadata["description"] == "Quoted description.")
    }

    @Test func handlesBOMAndCRLF() {
        let contents = "\u{FEFF}---\r\nname: bom\r\ndescription: Has a BOM.\r\n---\r\nBody\r\n"
        let result = SkillCatalog.parseSkillFile(contents)
        #expect(result?.metadata["name"] == "bom")
        #expect(result?.metadata["description"] == "Has a BOM.")
        #expect(result?.body == "Body")
    }

    @Test func missingFrontmatterReturnsNil() {
        #expect(SkillCatalog.parseSkillFile("# Just markdown\nBody") == nil)
    }

    @Test func unclosedFrontmatterReturnsNil() {
        let contents = """
        ---
        name: broken
        description: Never closed.
        Body
        """
        #expect(SkillCatalog.parseSkillFile(contents) == nil)
    }

    @Test func emptyBodyIsAllowed() {
        let contents = """
        ---
        name: empty
        description: No body.
        ---
        """
        let result = SkillCatalog.parseSkillFile(contents)
        #expect(result?.metadata["name"] == "empty")
        #expect(result?.body == "")
    }
}

// MARK: - isValidSkillName

@Suite("isValidSkillName")
struct IsValidSkillNameTests {
    @Test func acceptsLowercaseAlphanumericsAndHyphens() {
        #expect(SkillCatalog.isValidSkillName("swift-testing"))
        #expect(SkillCatalog.isValidSkillName("a1"))
        #expect(SkillCatalog.isValidSkillName("-"))
    }

    @Test func rejectsInvalidNames() {
        #expect(!SkillCatalog.isValidSkillName(""))
        #expect(!SkillCatalog.isValidSkillName("Upper"))
        #expect(!SkillCatalog.isValidSkillName("has space"))
        #expect(!SkillCatalog.isValidSkillName("under_score"))
        #expect(!SkillCatalog.isValidSkillName(String(repeating: "a", count: 65)))
    }
}

// MARK: - promptBlock

@Suite("promptBlock")
struct PromptBlockTests {
    private func skill(_ name: String, _ description: String) -> Skill {
        Skill(
            name: name,
            description: description,
            path: "/tmp/\(name)/SKILL.md",
            directory: "/tmp/\(name)"
        )
    }

    @Test func emptyCatalogRendersNothing() {
        #expect(SkillCatalog(skills: []).promptBlock().isEmpty)
    }

    @Test func listsEachSkillWithNameAndDescription() {
        let catalog = SkillCatalog(skills: [
            skill("alpha", "First skill."),
            skill("beta", "Second skill."),
        ])
        let block = catalog.promptBlock()
        #expect(block.contains("### AVAILABLE SKILLS"))
        #expect(block.contains("- alpha — First skill."))
        #expect(block.contains("- beta — Second skill."))
        #expect(block.contains("use_skill"))
    }

    @Test func truncatesLongDescriptions() {
        let catalog = SkillCatalog(skills: [skill("long", String(repeating: "x", count: 300))])
        let block = catalog.promptBlock()
        #expect(block.contains(String(repeating: "x", count: 200)))
        #expect(!block.contains(String(repeating: "x", count: 201)))
    }
}

// MARK: - discover

@Suite("discover")
struct DiscoverTests {
    @Test func findsProjectUserAndBundledSkills() throws {
        let project = TempDir()
        let user = TempDir()
        let bundled = TempDir()
        try writeSkill(
            in: skillRoot(project, ".terrapincode/skills"),
            name: "project-skill",
            description: "From the project."
        )
        try writeSkill(in: skillRoot(user, "skills"), name: "user-skill", description: "From the user.")
        let bundledFile = try writeBundledSkill(
            in: bundled.url,
            name: "bundled-skill",
            description: "Shipped with the binary."
        )

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            bundledSkillFiles: [bundledFile],
            userDirectory: user.url
        )
        #expect(catalog.skills.map(\.name) == ["project-skill", "user-skill", "bundled-skill"])
    }

    @Test func projectSkillShadowsUserAndBundledSkill() throws {
        let project = TempDir()
        let user = TempDir()
        let bundled = TempDir()
        try writeSkill(
            in: skillRoot(project, ".terrapincode/skills"),
            name: "shared",
            description: "Project version."
        )
        try writeSkill(in: skillRoot(user, "skills"), name: "shared", description: "User version.")
        let bundledFile = try writeBundledSkill(in: bundled.url, name: "shared", description: "Bundled version.")

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            bundledSkillFiles: [bundledFile],
            userDirectory: user.url
        )
        #expect(catalog.skills.count == 1)
        #expect(catalog.skills[0].description == "Project version.")
    }

    @Test func extraDirectoriesBeatBundledSkills() throws {
        let project = TempDir()
        let user = TempDir()
        let extra = TempDir()
        let bundled = TempDir()
        try writeSkill(in: extra.url, name: "shared", description: "Extra version.")
        let bundledFile = try writeBundledSkill(in: bundled.url, name: "shared", description: "Bundled version.")

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            extraDirectories: [extra.url.path],
            bundledSkillFiles: [bundledFile],
            userDirectory: user.url
        )
        #expect(catalog.skills.map(\.description) == ["Extra version."])
    }

    @Test func directoriesWithoutSkillFileAreSkipped() throws {
        let project = TempDir()
        let user = TempDir()
        let root = try skillRoot(project, ".terrapincode/skills")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-skill", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeSkill(in: root, name: "real-skill", description: "Real.")

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.map(\.name) == ["real-skill"])
    }

    @Test func missingDescriptionIsSkipped() throws {
        let project = TempDir()
        let user = TempDir()
        let root = try skillRoot(project, ".terrapincode/skills")
        let dir = root.appendingPathComponent("no-desc", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: no-desc
        ---
        Body
        """
        .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.isEmpty)
    }

    @Test func missingFrontmatterIsSkipped() throws {
        let project = TempDir()
        let user = TempDir()
        let root = try skillRoot(project, ".terrapincode/skills")
        let dir = root.appendingPathComponent("no-fm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# Just markdown".write(
            to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.isEmpty)
    }

    @Test func skillFileNameMatchesCaseInsensitively() throws {
        let project = TempDir()
        let user = TempDir()
        try writeSkill(
            in: skillRoot(project, ".terrapincode/skills"),
            name: "lowercase-file",
            description: "Lowercase file.",
            fileName: "skill.md"
        )

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.map(\.name) == ["lowercase-file"])
    }

    @Test func frontmatterNameWinsOverDirectoryName() throws {
        let project = TempDir()
        let user = TempDir()
        let root = try skillRoot(project, ".terrapincode/skills")
        let dir = root.appendingPathComponent("dir-name", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: fm-name
        description: Frontmatter name.
        ---
        Body
        """
        .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.map(\.name) == ["fm-name"])
    }

    @Test func invalidNameFallsBackToDirectoryName() throws {
        let project = TempDir()
        let user = TempDir()
        let root = try skillRoot(project, ".terrapincode/skills")
        let dir = root.appendingPathComponent("valid-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        ---
        name: Invalid Name
        description: Bad frontmatter name.
        ---
        Body
        """
        .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let catalog = SkillCatalog.discover(cwd: project.url.path, userDirectory: user.url)
        #expect(catalog.skills.map(\.name) == ["valid-dir"])
    }

    @Test func emptyCwdStillFindsUserSkills() throws {
        let user = TempDir()
        try writeSkill(in: skillRoot(user, "skills"), name: "user-skill", description: "From the user.")

        let catalog = SkillCatalog.discover(cwd: "", userDirectory: user.url)
        #expect(catalog.skills.map(\.name) == ["user-skill"])
    }

    @Test func bundledFlatFilesAreDiscovered() throws {
        let project = TempDir()
        let user = TempDir()
        let bundled = TempDir()
        let first = try writeBundledSkill(in: bundled.url, name: "alpha", description: "First.")
        let second = try writeBundledSkill(in: bundled.url, name: "beta", description: "Second.")

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            bundledSkillFiles: [first, second],
            userDirectory: user.url
        )
        #expect(catalog.skills.map(\.name) == ["alpha", "beta"])
    }

    @Test func bundledFileFallsBackToBaseName() throws {
        let project = TempDir()
        let user = TempDir()
        let bundled = TempDir()
        let file = bundled.url.appendingPathComponent("fallback-name.md")
        try """
        ---
        description: No name in frontmatter.
        ---
        Body
        """
        .write(to: file, atomically: true, encoding: .utf8)

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            bundledSkillFiles: [file],
            userDirectory: user.url
        )
        #expect(catalog.skills.map(\.name) == ["fallback-name"])
    }

    @Test func bundledFileWithoutFrontmatterIsSkipped() throws {
        let project = TempDir()
        let user = TempDir()
        let bundled = TempDir()
        let file = bundled.url.appendingPathComponent("no-fm.md")
        try "# Just markdown".write(to: file, atomically: true, encoding: .utf8)

        let catalog = SkillCatalog.discover(
            cwd: project.url.path,
            bundledSkillFiles: [file],
            userDirectory: user.url
        )
        #expect(catalog.skills.isEmpty)
    }
}
