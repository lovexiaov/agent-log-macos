import Foundation
import KSCrash

/// 崩溃与卡顿采集：基于 KSCrash（MIT）。报告落盘，启动时转成 crash entry。
public enum CrashReporter {
    /// 安装崩溃监控；崩溃/历史报告经 sink 写入 AgentLog 文件流。
    public static func install(sink: @escaping (AgentLogEntry) -> Void) {
        let crash = KSCrash.sharedInstance()
        crash.monitoring = [.machException, .signal, .cppException, .objcException, .deadlock, .memoryTermination]
        // 主线程卡顿阈值（秒）。KSCrash 的 deadlock watchdog 会据此判定 hang。
        // TODO: 核对 KSCrash 2.x 实际属性名（可能为 deadlockWatchdogInterval 或类似）
        crash.deadlockWatchdogInterval = 2.0
        let installed = crash.install()
        if !installed {
            sink(AgentLogEntry(level: "error",
                service: Bundle.main.bundleIdentifier ?? "app",
                subsystem: "agent.crash", category: "crash",
                eventType: AgentEventType.crash.rawValue,
                sessionId: Session.id, agentAuto: true,
                message: "KSCrash install failed"))
            return
        }
        // 启动时把上次崩溃报告转成结构化条目
        // TODO: 核对 KSCrashInstallation 实际 API（standard()/sendAllReports 闭包类型）
        let installation = KSCrashInstallation.standard()
        installation?.install()
        installation?.sendAllReports { reports, _, _ in
            guard let reports = reports as? [String] else { return }
            for raw in reports {
                sink(AgentLogEntry(level: "critical",
                    service: Bundle.main.bundleIdentifier ?? "app",
                    subsystem: "agent.crash", category: "crash",
                    eventType: AgentEventType.crash.rawValue,
                    sessionId: Session.id, agentAuto: true,
                    message: "Crash report available",
                    payload: ["raw": .string(raw)]))
            }
        }
    }
}
