//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ConsoleLogger.swift
//

import os

public struct ConsoleLogger: Loggable, Sendable {
    public init() {}
    
    public func debug(_ message: String) {
        fputs("[DEBUG] \(message)\n", stderr)
    }
}
