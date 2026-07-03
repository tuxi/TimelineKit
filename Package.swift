// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TimelineKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // MARK: - Individual module libraries (V8)
        .library(
            name: "TimelineKitCore",
            targets: ["TimelineKitCore"]
        ),
        .library(
            name: "TimelineKitRender",
            targets: ["TimelineKitRender"]
        ),
        .library(
            name: "TimelineKitUIShared",
            targets: ["TimelineKitUIShared"]
        ),
        .library(
            name: "TimelineKitUIiOS",
            targets: ["TimelineKitUIiOS"]
        ),
        .library(
            name: "TimelineKitUIMac",
            targets: ["TimelineKitUIMac"]
        ),

        // MARK: - Umbrella (backward compatibility)
        .library(
            name: "TimelineKit",
            targets: ["TimelineKit"]
        ),

        // MARK: - Executables (V8)
        .executable(
            name: "timelinekit",
            targets: ["TimelineKitCLI"]
        ),
        .executable(
            name: "timelinekit-mcp",
            targets: ["TimelineKitMCP"]
        ),
    ],
    dependencies: [

    ],
    targets: [
        // MARK: - V8 Core layer
        .target(
            name: "TimelineKitCore",
            dependencies: []
        ),

        // MARK: - V8 Render layer
        .target(
            name: "TimelineKitRender",
            dependencies: ["TimelineKitCore"]
        ),

        // MARK: - V8 UI shared layer
        .target(
            name: "TimelineKitUIShared",
            dependencies: ["TimelineKitCore", "TimelineKitRender"]
        ),

        // MARK: - V8 Platform UI targets
        .target(
            name: "TimelineKitUIiOS",
            dependencies: ["TimelineKitUIShared", "TimelineKitRender"]
        ),
        .target(
            name: "TimelineKitUIMac",
            dependencies: ["TimelineKitUIShared", "TimelineKitRender"]
        ),

        // MARK: - V8 Executable targets
        .executableTarget(
            name: "TimelineKitCLI",
            dependencies: ["TimelineKitCore", "TimelineKitRender", "TimelineKitUIShared"]
        ),
        .executableTarget(
            name: "TimelineKitMCP",
            dependencies: ["TimelineKitCore", "TimelineKitRender", "TimelineKitUIShared"]
        ),

        // MARK: - Umbrella target (backward compatibility)
        // 现有源码逐步迁移到子模块。umbrella 直接依赖所有子模块并通过
        // @_exported import 重新导出，保证留在 TimelineKit 中的代码能继续找到已迁出的类型。
        .target(
            name: "TimelineKit",
            dependencies: [
                "TimelineKitCore",
                "TimelineKitRender",
                "TimelineKitUIShared",
                "TimelineKitUIiOS",
            ]
        ),
    ]
)
