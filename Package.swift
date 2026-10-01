// swift-tools-version: 6.2

import Foundation
import PackageDescription

func metadataLinkerSettings(_ environment: String) -> [LinkerSetting] {
    ProcessInfo.processInfo.environment[environment].map { directory in
        [
            .unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", directory + "/HelperInfo.plist",
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__launchd_plist",
                "-Xlinker", directory + "/HelperLaunchd.plist",
            ])
        ]
    } ?? []
}

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AwakeCore", targets: ["AwakeCore"]),
        .library(name: "AwakeSystem", targets: ["AwakeSystem"]),
        .executable(name: "AwakeHelper", targets: ["AwakeHelper"]),
        .executable(name: "awake", targets: ["AwakeCLI"]),
        .executable(name: "AwakeApp", targets: ["AwakeApp"]),
        .executable(name: "AwakeSudo", targets: ["AwakeSudo"]),
        .executable(name: "AwakeSudoHelper", targets: ["AwakeSudoHelper"]),
    ],
    targets: [
        .target(name: "AwakeCore"),
        .target(name: "AwakeSystem", dependencies: ["AwakeCore"]),
        .executableTarget(
            name: "AwakeHelper", dependencies: ["AwakeSystem", "AwakeCore"],
            linkerSettings: metadataLinkerSettings("AWAKE_HELPER_METADATA")),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore"]),
        .executableTarget(
            name: "AwakeCLI", dependencies: ["AwakeSystem", "AwakeCore"]),
        .testTarget(name: "AwakeCLITests", dependencies: ["AwakeCLI"]),
        .executableTarget(
            name: "AwakeApp", dependencies: ["AwakeSystem", "AwakeCore"]),
        .testTarget(name: "AwakeAppTests", dependencies: ["AwakeApp"]),
        .testTarget(name: "AwakeSystemTests", dependencies: ["AwakeSystem"]),
        .executableTarget(name: "AwakeSudo", dependencies: ["AwakeSystem"]),
        .executableTarget(
            name: "AwakeSudoHelper", dependencies: ["AwakeSystem", "AwakeCore"],
            linkerSettings: metadataLinkerSettings("AWAKE_SUDO_METADATA")),
    ],
    swiftLanguageModes: [.v6]
)
