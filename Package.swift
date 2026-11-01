// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentLog",
    platforms: [
        // 用户确认：最低 macOS 12+（Pulse 要求）
        .macOS(.v12)
    ],
    products: [
        .library(name: "AgentLog", targets: ["AgentLog"]),
    ],
    dependencies: [
        // 统一日志 API
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // 本地 SQLite 结构化存储 + 自动 URLSession 网络捕获 + 查看器（MIT）
        // 注：接入时请确认 Pulse 最新版本号
        .package(url: "https://github.com/kean/Pulse.git", from: "2.0.0"),
        // 开源崩溃/卡顿采集（MIT）
        .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AgentLog",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Pulse", package: "Pulse"),
                .product(name: "KSCrash", package: "KSCrash"),
            ]
        ),
        .testTarget(
            name: "AgentLogTests",
            dependencies: ["AgentLog"]
        ),
    ]
)
