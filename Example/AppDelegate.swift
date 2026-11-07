import Cocoa
import AgentLog

/// 示例：业务侧零埋点接入 + 手动日志演示。
///
/// 把本文件作为 macOS App 的 AppDelegate 即可（已标注 `@main`）。
/// bootstrap 时自动埋点（UI / 网络 / 崩溃 / 卡顿）默认全开，
/// JSONL 落盘到 `~/Library/Logs/<bundleIdentifier>/agent-log.jsonl`，可被 Agent 按行消费。
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 一处接入：自动埋点默认全开，JSONL 落盘到 ~/Library/Logs/<bundle>/agent-log.jsonl
        AgentLog.bootstrap(subsystem: "com.yourapp.agent")

        // 1) 各档级别（category 用于归类，traceId 用于跨端串联）
        AgentLog.trace("boot span", category: "lifecycle", payload: ["span": "boot"])
        AgentLog.debug("debug detail", category: "lifecycle", traceId: "trace_abc", payload: ["step": "init"])
        AgentLog.info("app launched", category: "lifecycle")
        AgentLog.warning("low disk space", category: "system", payload: ["freeMb": 42])
        AgentLog.error("request failed", category: "net", payload: ["host": "api.example.com", "status": 503])

        // 2) 跨端串联：traceId 贯穿；业务键（userId / method）进 payload
        AgentLog.info("user signed in", traceId: "trace_abc", payload: ["userId": "u-1234", "method": "oauth"])

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
    }
}
