//
// TerrapinPilot
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// AgentRunTests.swift
//

import Foundation
import Stores
import Testing

@testable import Agent

// MARK: - Basic Turns

@Suite("Agent.run")
struct AgentRunTests {
    @Test("a final answer is streamed and saved to history")
    func finalAnswer() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "Hi there!"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "Hello", recorder: recorder)

        #expect(recorder.chunks.joined() == "Hi there!")
        #expect(harness.llm.callCount == 1)

        let history = await harness.store.history(for: harness.sessionId) ?? []
        #expect(history.count == 3)
        #expect(history[0].role == "system")
        #expect(history[1].role == "user")
        #expect(history[1].content == "Hello")
        #expect(history[2].role == "assistant")
        #expect(history[2].content == "Hi there!")
    }

    @Test("a second turn reuses the saved history")
    func secondTurnReusesHistory() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: "Hello!")),
                .response(LLMResponse(content: "Again.")),
            ])
        )
        let recorder = Recorder()
        await harness.run(prompt: "Hi", recorder: recorder)
        await harness.run(prompt: "Again?", recorder: recorder)

        let second = harness.llm.calls[1].messages
        #expect(second.count == 4)
        #expect(second[0].role == "system")
        #expect(second[0].content == harness.llm.calls[0].messages[0].content)
        #expect(second[1].content == "Hi")
        #expect(second[2].content == "Hello!")
        #expect(second[3].content == "Again?")
    }

    @Test("the tool registry is prepared before the loop")
    func registryPrepared() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(harness.provider.preparedCwds == [harness.cwd])
    }

    @Test("the context window is recorded on the session")
    func contextWindowRecorded() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            contextWindow: 4096
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(await harness.store.contextWindow(for: harness.sessionId) == 4096)
    }

    // MARK: - Tool Calls

    @Test("tool calls are executed and fed back to the model")
    func toolCallRoundTrip() async {
        let tool = testToolDefinition("run_command")
        let toolCall = ToolCall(
            id: "call_1",
            function: FunctionCall(name: "run_command", arguments: #"{"command":"ls"}"#)
        )
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: nil, toolCalls: [toolCall])),
                .response(LLMResponse(content: "Done.")),
            ]),
            tools: [tool],
            results: ["run_command": "file.txt"]
        )
        let recorder = Recorder()
        await harness.run(prompt: "List files", tools: [tool], recorder: recorder)

        // The tool ran with the model's arguments.
        #expect(harness.provider.executions.count == 1)
        #expect(harness.provider.executions[0].name == "run_command")
        #expect(harness.provider.executions[0].argsJSON == #"{"command":"ls"}"#)

        // The model was called twice; the second call sees the tool result.
        #expect(harness.llm.callCount == 2)
        let secondCall = harness.llm.calls[1].messages
        #expect(secondCall.count == 4)
        #expect(secondCall[2].role == "assistant")
        #expect(secondCall[2].toolCalls?.count == 1)
        #expect(secondCall[3].role == "tool")
        #expect(secondCall[3].content == "file.txt")
        #expect(secondCall[3].toolCallId == "call_1")

        // Plan updates bracket the tool batch.
        let plans = recorder.updates("plan")
        #expect(plans.count == 2)
        #expect((plans[0]["entries"] as? [[String: Any]])?.first?["status"] as? String == "in_progress")
        #expect((plans[1]["entries"] as? [[String: Any]])?.first?["status"] as? String == "completed")

        // History ends with the final answer.
        let history = await harness.store.history(for: harness.sessionId) ?? []
        #expect(history.last?.content == "Done.")
        #expect(recorder.chunks.joined() == "Done.")
    }

    @Test("multiple tool calls in one response run in order")
    func multipleToolCalls() async {
        let toolA = testToolDefinition("tool_a")
        let toolB = testToolDefinition("tool_b")
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: nil, toolCalls: [
                    ToolCall(id: "call_a", function: FunctionCall(name: "tool_a", arguments: "{}")),
                    ToolCall(id: "call_b", function: FunctionCall(name: "tool_b", arguments: "{}")),
                ])),
                .response(LLMResponse(content: "ok")),
            ]),
            tools: [toolA, toolB],
            results: ["tool_a": "A", "tool_b": "B"]
        )
        let recorder = Recorder()
        await harness.run(prompt: "go", tools: [toolA, toolB], recorder: recorder)

        #expect(harness.provider.executions.map(\.name) == ["tool_a", "tool_b"])
        let history = await harness.store.history(for: harness.sessionId) ?? []
        let toolMessages = history.filter { $0.role == "tool" }
        #expect(toolMessages.map(\.content) == ["A", "B"])
    }

    @Test("an unknown tool yields an error result and the turn continues")
    func unknownTool() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: nil, toolCalls: [
                    ToolCall(id: "call_1", function: FunctionCall(name: "nope", arguments: "{}")),
                ])),
                .response(LLMResponse(content: "ok")),
            ])
        )
        let recorder = Recorder()
        await harness.run(prompt: "go", recorder: recorder)

        let history = await harness.store.history(for: harness.sessionId) ?? []
        let toolMessage = history.first { $0.role == "tool" }
        #expect(toolMessage?.content == "Error: Unknown tool 'nope'")
        #expect(history.last?.content == "ok")
    }

    @Test("the loop stops at fifty turns")
    func maxTurns() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(
                responses: [],
                repeating: .response(LLMResponse(content: nil, toolCalls: [
                    ToolCall(id: "call_1", function: FunctionCall(name: "tool_a", arguments: "{}")),
                ]))
            ),
            tools: [testToolDefinition("tool_a")]
        )
        let recorder = Recorder()
        await harness.run(prompt: "go", tools: [testToolDefinition("tool_a")], recorder: recorder)

        #expect(harness.llm.callCount == 50)
        #expect(harness.provider.executions.count == 50)
    }

    // MARK: - Errors

    @Test("an HTTP error warns about the server connection")
    func httpErrorWarning() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.failure(LLMError.httpStatus(503, body: "boom"))])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(recorder.chunks == ["⚠️ Error connecting to local AI server."])
    }

    @Test("a dropped stream warns about the connection")
    func streamInterruptedWarning() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.failure(LLMError.streamInterrupted)])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(recorder.chunks == ["⚠️ Connection to AI server dropped mid-response."])
    }

    @Test("an unparseable response warns about parsing")
    func badResponseWarning() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.failure(LLMError.badResponse)])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(recorder.chunks == ["⚠️ Failed to parse response from AI server."])
    }

    @Test("other errors warn with their description")
    func genericErrorWarning() async {
        struct Boom: Error {}
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.failure(Boom())])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(recorder.chunks.first?.hasPrefix("⚠️ Error during agent turn: ") == true)
    }

    @Test("history is saved even when the LLM call fails")
    func historySavedOnFailure() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.failure(LLMError.badResponse)])
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        let history = await harness.store.history(for: harness.sessionId) ?? []
        #expect(history.count == 2)
        #expect(history[1].content == "hi")
    }

    // MARK: - Cancellation

    @Test("cancelling the task stops the turn and saves history")
    func cancelledTurn() async {
        let harness = makeAgentHarness(llm: FakeLLMClient(responses: [.hang]))
        let recorder = Recorder()
        let task = Task {
            await harness.run(prompt: "hi", recorder: recorder)
        }
        task.cancel()
        await task.value

        let history = await harness.store.history(for: harness.sessionId) ?? []
        #expect(history.count == 2)
        #expect(history[1].content == "hi")
        #expect(recorder.chunks.isEmpty)
    }

    @Test("cancelling between tool calls leaves a placeholder result")
    func cancelledBetweenToolCalls() async {
        let toolA = testToolDefinition("tool_a")
        let toolB = testToolDefinition("tool_b")
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: nil, toolCalls: [
                    ToolCall(id: "call_1", function: FunctionCall(name: "tool_a", arguments: "{}")),
                    ToolCall(id: "call_2", function: FunctionCall(name: "tool_b", arguments: "{}")),
                ])),
            ]),
            tools: [toolA, toolB]
        )
        // The first tool execution cancels the agent's task, so the second
        // call in the batch hits the Task.isCancelled check.
        let box = TaskBox()
        harness.provider.onExecute = { _ in box.cancel() }

        let recorder = Recorder()
        let gate = Gate()
        let task = Task {
            await gate.wait()
            await harness.run(prompt: "go", tools: [toolA, toolB], recorder: recorder)
        }
        box.set(task)
        gate.open()
        await task.value

        #expect(harness.provider.executions.count == 1)
        let history = await harness.store.history(for: harness.sessionId) ?? []
        let toolMessages = history.filter { $0.role == "tool" }
        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].content == "Result of tool_a")
        #expect(toolMessages[1].content == "Cancelled by user before this tool ran.")
        #expect(toolMessages[1].toolCallId == "call_2")
    }

    // MARK: - Slot Mapping

    @Test("the same session always maps to the same slot")
    func slotStability() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [
                .response(LLMResponse(content: "one")),
                .response(LLMResponse(content: "two")),
            ]),
            slotCount: 4
        )
        let recorder = Recorder()
        await harness.run(prompt: "first", recorder: recorder)
        await harness.run(prompt: "second", recorder: recorder)

        let first = harness.llm.calls[0].slotId
        let second = harness.llm.calls[1].slotId
        #expect(first != nil)
        #expect(first == second)
        if let first {
            #expect((0..<4).contains(first))
        }
    }

    @Test("no slots means the server picks")
    func noSlots() async {
        let harness = makeAgentHarness(
            llm: FakeLLMClient(responses: [.response(LLMResponse(content: "ok"))]),
            slotCount: 0
        )
        let recorder = Recorder()
        await harness.run(prompt: "hi", recorder: recorder)

        #expect(harness.llm.calls[0].slotId == nil)
    }
}
