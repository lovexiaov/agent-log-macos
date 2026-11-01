import Cocoa
import AgentLog

/// 示例：业务侧零埋点接入。编译进任意 macOS App 的 AppDelegate 即可。
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 一处接入，自动埋点默认全开（UI/网络/崩溃/卡顿）
        AgentLog.bootstrap(subsystem: "com.yourapp.agent")

        // 业务手动日志（agent_auto=false），正常写即可，无需任何埋点代码
        AgentLog.info("app launched", category: "lifecycle")

        // 需要跨端串联时传入 traceId（与 Web 端 traceId 同字段）
        AgentLog.info("user signed in", traceId: "trace_abc123")
    }
}
