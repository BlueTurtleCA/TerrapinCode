//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// NetworkMonitorTests.swift
//

import Foundation
import Testing

@testable import Helpers

@Suite("NetworkMonitor.transitionNote")
struct NetworkMonitorTransitionNoteTests {
    @Test func firstTurnOfflineReportsOffline() {
        let note = NetworkMonitor.transitionNote(online: false, previous: nil)
        #expect(note != nil)
        #expect(note?.contains("offline") == true)
    }

    @Test func onlineToOfflineReportsOffline() {
        let note = NetworkMonitor.transitionNote(online: false, previous: true)
        #expect(note != nil)
        #expect(note?.contains("offline") == true)
    }

    @Test func offlineToOnlineReportsRestored() {
        let note = NetworkMonitor.transitionNote(online: true, previous: false)
        #expect(note != nil)
        #expect(note?.contains("restored") == true)
    }

    @Test func firstTurnOnlineReportsNothing() {
        #expect(NetworkMonitor.transitionNote(online: true, previous: nil) == nil)
    }

    @Test func unchangedOnlineReportsNothing() {
        #expect(NetworkMonitor.transitionNote(online: true, previous: true) == nil)
    }

    @Test func unchangedOfflineReportsNothing() {
        #expect(NetworkMonitor.transitionNote(online: false, previous: false) == nil)
    }
}
