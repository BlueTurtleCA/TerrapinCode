//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// OSLogger.swift
//

import os

public struct OSLogger: Loggable, Sendable {
    let sharedLogger = os.Logger(subsystem: "ca.blueturtle.terrapincode", category: "ACP")
    
    public init() {}
    
    public func debug(_ message: String) {
        sharedLogger.notice("\(message, privacy: .public)")
    }
}
