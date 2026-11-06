//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// WorkspaceInstructionsTests.swift
//

import Foundation
import Testing

@testable import Agent

// MARK: - loadWorkspaceInstructions

@Suite("loadWorkspaceInstructions")
struct LoadWorkspaceInstructionsTests {
    @Test("finds AGENTS.md case-insensitively")
    func caseInsensitive() {
        let temp = TempDirectory()
        temp.writeFile("aGents.md", contents: "  use tabs  ")
        #expect(loadWorkspaceInstructions(from: temp.url.path) == "use tabs")
    }

    @Test("returns nil when the file is missing")
    func missing() {
        let temp = TempDirectory()
        #expect(loadWorkspaceInstructions(from: temp.url.path) == nil)
    }

    @Test("returns nil when the file is blank")
    func blank() {
        let temp = TempDirectory()
        temp.writeFile("AGENTS.md", contents: "   \n  ")
        #expect(loadWorkspaceInstructions(from: temp.url.path) == nil)
    }
}

// MARK: - findFile

@Suite("findFile")
struct FindFileTests {
    @Test("matches name and extension case-insensitively")
    func caseInsensitive() {
        let temp = TempDirectory()
        temp.writeFile("My.File", contents: "x")
        let url = findFile(named: "my", extension: "file", in: temp.url.path)
        #expect(url?.lastPathComponent == "My.File")
    }

    @Test("skips directories that share the file name")
    func skipsDirectories() {
        let temp = TempDirectory()
        // A directory named "agents.md" must not match.
        let dir = temp.url.appendingPathComponent("agents.md")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if Self.isCaseSensitive(temp.url) {
            // A differently-cased file can coexist with the directory and must win.
            temp.writeFile("AGENTS.md", contents: "x")
            let url = findFile(named: "agents", extension: "md", in: temp.url.path)
            #expect(url?.lastPathComponent == "AGENTS.md")
        } else {
            // On a case-insensitive filesystem the directory is the only entry,
            // so nothing may match.
            #expect(findFile(named: "agents", extension: "md", in: temp.url.path) == nil)
        }
    }

    /// Probes whether the file system at `url` distinguishes file names by case.
    private static func isCaseSensitive(_ url: URL) -> Bool {
        let lower = url.appendingPathComponent("caseprobe")
        try? "x".write(to: lower, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lower) }
        return !FileManager.default.fileExists(atPath: url.appendingPathComponent("CASEPROBE").path)
    }

    @Test("returns nil for a missing directory")
    func missingDirectory() {
        let temp = TempDirectory()
        let missing = temp.url.appendingPathComponent("nope").path
        #expect(findFile(named: "agents", extension: "md", in: missing) == nil)
    }
}
