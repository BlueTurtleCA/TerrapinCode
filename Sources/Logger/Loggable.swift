//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// Loggable.swift
//

import Foundation

public protocol Loggable: Sendable {
    func debug(_ message: String)
}

