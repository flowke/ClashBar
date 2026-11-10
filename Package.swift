// swift-tools-version: 6.2

import Foundation
import PackageDescription

let minimumMacOSVersion = "13.0"

// Keep the deployment target separate from LC_BUILD_VERSION.sdk. AppKit uses
// the latter to choose SDK-linked behavior, including native window controls.
// The package executable is also the product run by Xcode's package scheme.
func nativeMacOSLinkerSettings() throws -> [LinkerSetting] {
    #if os(macOS)
    let sdkPath: String
    if let sdkRoot = Context.environment["SDKROOT"], sdkRoot.hasPrefix("/") {
        sdkPath = sdkRoot
    } else {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            fatalError("Unable to locate the active macOS SDK for native UI linking.")
        }
        sdkPath = path
    }

    let settingsURL = URL(fileURLWithPath: sdkPath).appendingPathComponent("SDKSettings.plist")
    let settingsData = try Data(contentsOf: settingsURL)
    let settings = try PropertyListSerialization.propertyList(from: settingsData, format: nil) as? [String: Any]
    guard let sdkVersion = settings?["Version"] as? String, !sdkVersion.isEmpty else {
        fatalError("The active macOS SDK has no version in SDKSettings.plist.")
    }

    return [.unsafeFlags([
        "-Xlinker", "-platform_version",
        "-Xlinker", "macos",
        "-Xlinker", minimumMacOSVersion,
        "-Xlinker", sdkVersion,
    ])]
    #else
    return []
    #endif
}

let package = Package(
    name: "ClashBar",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(minimumMacOSVersion),
    ],
    products: [
        .executable(name: "ClashBar", targets: ["ClashBar"]),
        .executable(name: "ClashBarProxyHelper", targets: ["ClashBarProxyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.4.0"),
    ],
    targets: [
        .target(
            name: "ProxyHelperShared",
            path: "Sources/ProxyHelperShared"),
        .executableTarget(
            name: "ClashBar",
            dependencies: ["ProxyHelperShared", .product(name: "Yams", package: "Yams")],
            path: "Sources/ClashBar",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: try nativeMacOSLinkerSettings()),
        .executableTarget(
            name: "ClashBarProxyHelper",
            dependencies: ["ProxyHelperShared"],
            path: "Sources/ProxyHelper/Daemon"),
        .testTarget(
            name: "ClashBarTests",
            dependencies: ["ClashBar"],
            path: "Tests/ClashBarTests"),
    ])
