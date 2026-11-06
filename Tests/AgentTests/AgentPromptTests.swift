//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// AgentPromptTests.swift
//

import Foundation
import Testing

@testable import Agent

// The test templates separate every placeholder with "|", so the built
// system prompt splits into [CWD, TERMINAL_TOOLS, NETWORK_STATUS, SKILLS,
// CUSTOM_INSTRUCTIONS].

@Suite("Agent system prompt")
struct AgentPromptTests {
    /// The system prompt the model saw on the first LLM call.
    private func systemPrompt(_ harness: AgentHarness) -> String {
        guard harness.llm.callCount > 0 else { return "" }
        return harness.llm.calls[0].messages.first?.content ?? ""
    }

    private func blocks(_ prompt: String) -> [String] {
        prompt.components(separatedBy: "|")
    }

    @Test("placeholders are substituted for a known client")
    func placeholdersSubstituted() async {
        let tool = testToolDefinition("run_command")
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            tools: [tool],
            skills: [testSkill]
        )
        harness.temp.writeFile("AGENTS.md", contents: "Always use tabs.")
        let recorder = Recorder()
        await harness.run(prompt: "hi", tools: [tool], recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts.count == 5)
        #expect(systemPrompt(harness).hasPrefix("XCODE "))
        #expect(parts[0] == "XCODE " + harness.cwd)
        #expect(parts[1].contains("### TERMINAL & SHELL COMMANDS"))
        #expect(parts[2].isEmpty) // online: no network status block
        #expect(parts[3].contains("### AVAILABLE SKILLS"))
        #expect(parts[3].contains("test-skill"))
        #expect(parts[4].contains("### PROJECT-SPECIFIC INSTRUCTIONS (AGENTS.MD)"))
        #expect(parts[4].contains("Always use tabs."))
    }

    @Test("the terminal block is omitted without run_command")
    func noTerminalBlock() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", tools: [testToolDefinition("other_tool")], recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[1].isEmpty)
    }

    @Test("no AGENTS.md means no custom instructions block")
    func noAgentsMd() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[4].isEmpty)
    }

    @Test("no skills means an empty skills block")
    func noSkills() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let parts = blocks(systemPrompt(harness))
        #expect(parts[3].isEmpty)
    }

    @Test("unknown clients fall back to the generic template")
    func genericFallback() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", client: .generic(name: "Zed"), recorder: recorder)

        #expect(systemPrompt(harness).hasPrefix("GENERIC "))
    }
}
