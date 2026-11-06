//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// XcodeMCPBridgeClientTests.swift
//

import Foundation
import Testing

@testable import Tools

// MARK: - Shared fixtures

/// The exact message Xcode's mcpbridge returns when the agent has not been
/// approved to use Xcode's tools yet.
private let approvalMessage = """
    This agent isn't approved to use Xcode's tools yet. Call XcodeOpenWorkspace or XcodeNewProject first: opening or creating a project is what asks the user to approve this agent, together with access to that project's folder.
    """

// MARK: - isNotApproved

@Suite("isNotApproved")
struct IsNotApprovedTests {
    @Test("matches the approval message")
    func matchesApprovalMessage() {
        #expect(XcodeMCPBridgeClient.isNotApproved(approvalMessage))
    }

    @Test("matches case-insensitively")
    func matchesCaseInsensitively() {
        #expect(XcodeMCPBridgeClient.isNotApproved(approvalMessage.uppercased()))
    }

    @Test("ignores other results")
    func ignoresOtherResults() {
        #expect(!XcodeMCPBridgeClient.isNotApproved("Built successfully."))
        #expect(!XcodeMCPBridgeClient.isNotApproved("Error: No response from Xcode mcpbridge"))
        #expect(!XcodeMCPBridgeClient.isNotApproved(#"{"content":"     1\tlet a = 1"}"#))
        #expect(!XcodeMCPBridgeClient.isNotApproved(""))
    }
}

// MARK: - isBridgeError

@Suite("isBridgeError")
struct IsBridgeErrorTests {
    @Test("RPC-level error strings are errors")
    func rpcErrorStrings() {
        #expect(XcodeMCPBridgeClient.isBridgeError("Error: No response from Xcode mcpbridge"))
        #expect(XcodeMCPBridgeClient.isBridgeError("Error executing tool 'BuildProject': boom"))
    }

    @Test("JSON error payloads are errors")
    func jsonErrorPayloads() {
        #expect(XcodeMCPBridgeClient.isBridgeError(#"{"data":"Missing required parameter 'sourcePath'","type":"error"}"#))
    }

    @Test("the not-approved message is an error")
    func notApprovedIsError() {
        #expect(XcodeMCPBridgeClient.isBridgeError(approvalMessage))
    }

    @Test("successful results are not errors")
    func successfulResults() {
        #expect(!XcodeMCPBridgeClient.isBridgeError("File written successfully: /tmp/x"))
        #expect(!XcodeMCPBridgeClient.isBridgeError("Built successfully."))
        #expect(!XcodeMCPBridgeClient.isBridgeError(#"{"content":"     1\tlet a = 1"}"#))
        #expect(!XcodeMCPBridgeClient.isBridgeError(#"{"workspaceIdentifier":"workspace-LR49lofe9w"}"#))
    }
}
