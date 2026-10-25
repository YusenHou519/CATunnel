// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CATunnel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
        .executable(name: "CATunnel", targets: ["CATunnel"]),
        .executable(name: "TunnelCoreChecks", targets: ["TunnelCoreChecks"]),
        .executable(name: "TunnelIntegrationChecks", targets: ["TunnelIntegrationChecks"]),
        .executable(name: "FixedEntryIntegrationChecks", targets: ["FixedEntryIntegrationChecks"]),
        .executable(name: "FixedEntryInstallIntegrationChecks", targets: ["FixedEntryInstallIntegrationChecks"])
    ],
    targets: [
        .target(name: "TunnelCore"),
        .executableTarget(name: "CATunnel", dependencies: ["TunnelCore"]),
        .executableTarget(name: "TunnelCoreChecks", dependencies: ["TunnelCore"], path: "Tests/TunnelCoreTests"),
        .executableTarget(name: "TunnelIntegrationChecks", dependencies: ["TunnelCore"], path: "Tests/TunnelIntegrationChecks"),
        .executableTarget(name: "FixedEntryIntegrationChecks", dependencies: ["TunnelCore"], path: "Tests/FixedEntryIntegrationChecks"),
        .executableTarget(name: "FixedEntryInstallIntegrationChecks", dependencies: ["TunnelCore"], path: "Tests/FixedEntryInstallIntegrationChecks")
    ]
)
