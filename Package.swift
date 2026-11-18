// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "agentbar", targets: ["AgentBar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentBar",
            path: "Sources/AgentBar"
        )
    ]
)
