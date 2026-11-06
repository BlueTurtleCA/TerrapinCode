//
//  Capabilities.swift
//  TerrapinCode
//
//  Created by Blue Turtle on 10/2/26.
//

public struct Capabilities: Sendable {
    public var readTextFile: Bool
    public var writeTextFile: Bool
    public var terminal: Bool

    public init(
        readTextFile: Bool = false,
        writeTextFile: Bool = false,
        terminal: Bool = false
    ) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
        self.terminal = terminal
    }
}
