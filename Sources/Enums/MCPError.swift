//
// TerrapinCode
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// MCPError.swift
//

import Foundation

public enum MCPError: Error {
    case failedToInitialize(_ underlyingError: Error?)
}
