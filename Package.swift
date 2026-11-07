// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentLog",
    platforms: [
        // Pulse 5.x / PulseLogHandler 5.x 实际要求 macOS 13.0 最低（实测 SPM 解析后报 13.0）。
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentLog", targets: ["AgentLog"]),
    ],
    dependencies: [
        // 统一日志 API（业务侧始终可用 swift-log 风格调用）
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        // 本地 SQLite 结构化存储 + 自动 URLSession 网络捕获 + 查看器（MIT）。
        // 仅当用户确认版本时解析；本项目以 JSONL 文件流为 Agent 主消费源，Pulse 为可选增强。
        .package(url: "https://github.com/kean/Pulse.git", from: "5.0.0"),
        // 将 Pulse 作为 SwiftLog 持久化后端（独立包，提供 PersistentLogHandler）。
        // 与 Pulse 5.x 对齐：PulseLogHandler 3.0.0 起可用，5.x 对应 Pulse 5.x。
        .package(url: "https://github.com/kean/PulseLogHandler.git", from: "5.0.0"),
        // 开源崩溃/卡顿采集（MIT）。2.x 提供模块化 SPM 产品。
        .package(url: "https://github.com/kstenerud/KSCrash.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AgentLog",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Pulse", package: "Pulse"),
                .product(name: "PulseLogHandler", package: "PulseLogHandler"),
                .product(name: "Installations", package: "KSCrash"),
            ]
        ),
        .testTarget(
            name: "AgentLogTests",
            dependencies: ["AgentLog"]
        ),

        // 可编译的示例 target：直接 `swift build --target AgentLogExample` 即可验证
        // Example/main.swift 与 AgentLog 公共 API 的契约一致性（纯 Foundation，仅编译、不运行）。
        .executableTarget(
            name: "AgentLogExample",
            dependencies: ["AgentLog"],
            path: "Example"
        ),
    ]
)
