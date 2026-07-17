// swift-tools-version: 6.1
import PackageDescription

let linuxSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(
        [
            "-cross-module-optimization",
            "-whole-module-optimization",
            "-Osize",
        ], .when(platforms: [.linux], configuration: .release))
]

let linuxLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        [
            "-Xlinker", "-z", "-Xlinker", "relro",
            "-Xlinker", "-z", "-Xlinker", "now",
        ], .when(platforms: [.linux]))
]

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let cliSwiftSettings: [SwiftSetting] = strict + linuxSwiftSettings

let package = Package(
    name: "CodingAgentKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CodingAgentKit", targets: ["CodingAgentKit"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "OpenCodeKit", targets: ["OpenCodeKit"]),
        .library(name: "ClaudeCodeKit", targets: ["ClaudeCodeKit"]),
        .library(name: "AgentTestSupport", targets: ["AgentTestSupport"]),
        .library(name: "CodingAgentKitApple", targets: ["CodingAgentKitApple"]),
        .executable(name: "codeagent", targets: ["CodeAgentCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.35.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AgentCore",
            dependencies: [
                .product(
                    name: "AsyncHTTPClient", package: "async-http-client",
                    condition: .when(platforms: [.linux])),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strict
        ),
        .target(
            name: "OpenCodeKit",
            dependencies: ["AgentCore"],
            swiftSettings: strict
        ),
        .target(
            name: "ClaudeCodeKit",
            dependencies: ["AgentCore"],
            swiftSettings: strict
        ),
        .target(
            name: "CodingAgentKit",
            dependencies: ["AgentCore", "OpenCodeKit", "ClaudeCodeKit"],
            swiftSettings: strict
        ),
        .target(
            name: "AgentTestSupport",
            dependencies: ["AgentCore", "OpenCodeKit", "ClaudeCodeKit"],
            swiftSettings: strict
        ),
        .target(
            name: "CodingAgentKitApple",
            dependencies: ["AgentCore", "OpenCodeKit", "ClaudeCodeKit"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "CodeAgentCLI",
            dependencies: [
                "CodingAgentKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: cliSwiftSettings,
            linkerSettings: linuxLinkerSettings
        ),
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["AgentCore", "AgentTestSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenCodeKitTests",
            dependencies: ["OpenCodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClaudeCodeKitTests",
            dependencies: ["ClaudeCodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
