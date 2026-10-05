// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnyShortcut",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AnyShortcut", targets: ["AnyShortcut"])],
    targets: [
        .target(name: "AnyShortcutCore"),
        .executableTarget(name: "AnyShortcut", dependencies: ["AnyShortcutCore"]),
        .testTarget(name: "AnyShortcutCoreTests", dependencies: ["AnyShortcutCore"]),
        .testTarget(name: "AnyShortcutUITests", dependencies: ["AnyShortcut", "AnyShortcutCore"]),
    ]
)
