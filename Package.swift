// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TerrapinCode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "terrapincode",
            targets: ["CLI"]
        )
    ],
    targets: [
        .target(name: "Logger"),
        .target(
            name: "Stores",
            dependencies: ["Logger"]
        ),
        .target(name: "Enums"),
        .target(
            name: "Helpers",
            dependencies: ["Stores"]
        ),
        .target(
            name: "Tools",
            dependencies: ["Logger", "Stores", "Helpers"]
        ),
        .target(
            name: "Agent",
            dependencies: ["Logger", "Stores", "Helpers", "Tools"]
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["Logger", "Stores", "Tools", "Enums", "Helpers", "Agent"],
            resources: [
                .process("Resources/system_prompt_xcode.txt"),
                .process("Resources/system_prompt_generic.txt"),
                .process("Resources/skills")
            ]
        ),
        .testTarget(
            name: "HelpersTests",
            dependencies: ["Helpers"]
        ),
        .testTarget(
            name: "ToolsTests",
            dependencies: ["Tools"]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: ["Agent"]
        )
    ]
)
