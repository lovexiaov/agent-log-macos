import Foundation
import AgentLog

// 示例：macOS 零埋点接入 + 手动日志演示。
//
// 本文件是 SwiftPM 可执行 target `AgentLogExample` 的入口，
// 直接 `swift build --target AgentLogExample` 即可编译，验证 Example 与
// AgentLog 公共 API 的契约一致性（纯 Foundation，不依赖 AppKit / 应用生命周期）。

// 一处接入：自动埋点（UI / 网络 / 崩溃 / 卡顿）默认全开，
// JSONL 落盘到 ~/Library/Logs/<bundleIdentifier>/agent-log.jsonl，可被 Agent 按行消费。
var config = AgentLogConfig(subsystem: "com.yourapp.agent.example")
config.minLevel = .trace // 让 6 档级别全部可见（含 critical）
// Schema v1.3：release 由配置统一盖章到每条事件（含自动埋点与崩溃），
// 导出 OTLP 时映射为 resource 的 service.version；不配置则不写该键。
config.release = "1.4.2"
AgentLog.bootstrap(config: config)

// 1) 各档级别（补齐契约 6 档：trace / debug / info / warning / error / critical）
AgentLog.trace("boot span", category: "lifecycle", payload: ["span": "boot"])
AgentLog.debug("debug detail", category: "lifecycle", traceId: "trace_abc", payload: ["step": "init"])
AgentLog.info("app launched", category: "lifecycle")
AgentLog.warning("low disk space", category: "system", payload: ["freeMb": 42])
AgentLog.error("request failed", category: "net", payload: ["host": "api.example.com", "status": 503])
AgentLog.critical("database unreachable", category: "db", payload: ["host": "db.example.com"])

// 2) 跨端串联：traceId 贯穿；业务键（userId / method）进 payload
AgentLog.info("user signed in", traceId: "trace_abc", payload: ["userId": "u-1234", "method": "oauth"])

// 2b) Schema v1.1：绑定 spanId，使该操作内所有事件共享一个 span。
//     导出到 OTLP 时日志行与链路节点用同一组 id，Agent 可精确对齐；
//     大写会被归一化为小写，非法值直接丢弃（绝不写出违规行）。
AgentLog.info(
    "invoice generated",
    category: "billing",
    traceId: "0123456789abcdef0123456789abcdef",
    spanId: "A1B2C3D4E5F60718",
    payload: ["invoice_id": "INV-9"])

// 3) 脱敏：默认敏感键（password / token / secret …）由 logger 层自动打码，业务侧无需关心
AgentLog.error("login failed", category: "auth", payload: [
    "password": "hunter2",
    "token": "topsecret",
    "username": "alice",
])

// 4) 自动埋点：crash 处理器已随 bootstrap 安装；未捕获异常会被记为 crash 事件。
//    JSONL 导出路径：
if let url = try? AgentLog.export() {
    print("导出路径: \(url.path)")
}

print("AgentLog example finished.")
