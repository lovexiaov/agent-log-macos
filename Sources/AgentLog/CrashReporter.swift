import Foundation

/// 崩溃与卡顿采集：基于 KSCrash 2.x（模块化 SPM，产品名 `Installations`）。
///
/// 设计原则（与「轻量、无后端依赖」一致）：
/// - 使用 `CrashInstallationConsole` —— 不向任何服务器上报，仅本地落盘 + 控制台输出。
/// - 报告存于 `KSCrash.shared.reportStore`，启动时读取并转成结构化 `crash` 条目写入 AgentLog 流。
/// - 整个集成用 `#if canImport(KSCrashInstallations)` 守卫：若消费者未引入 KSCrash，
///   崩溃采集自动降级（框架其余能力不受影响）。
#if canImport(KSCrashInstallations)
import KSCrashInstallations

public enum CrashReporter {
    /// 安装崩溃监控；历史/本次崩溃报告经 sink 写入 AgentLog 文件流。
    /// - Parameter sink: 接收结构化条目的回调（通常为 `AgentLog.appendRaw`）。
    public static func install(sink: @escaping (AgentLogEntry) -> Void) {
        let config = KSCrashConfiguration()
        // 仅启用生产安全的监测项；watchdog 为主线程卡顿/看门狗监测（2.6.1 用 .watchdog 取代旧 .deadlock）。
        // userReported 用于应用主动上报的非致命异常（含 `reportUserException`），缺失会导致此类报告被丢弃。
        config.monitors = [.machException, .signal, .nsException, .cppException, .watchdog, .userReported]
        config.reportStoreConfiguration.maxReportCount = 20

        let installation = CrashInstallationConsole.shared
        do {
            try installation.install(with: config)
        } catch {
            sink(AgentLogEntry(level: "error",
                service: Bundle.main.bundleIdentifier ?? "app",
                subsystem: "agent.crash", category: "crash",
                eventType: AgentEventType.crash.rawValue,
                sessionId: Session.id, agentAuto: true,
                message: "KSCrash install failed: \(error.localizedDescription)"))
            return
        }

        // 启动时把上次遗留的崩溃报告转成结构化条目
        CrashReporter.flushPendingReports(sink: sink)
    }

    /// 读取并转写 `KSCrash.reportStore` 中所有遗留报告进 sink（不重新 install KSCrash）。
    /// 供 `install` 启动时扫描，以及测试时二次触发。
    public static func flushPendingReports(sink: @escaping (AgentLogEntry) -> Void) {
        guard let store = KSCrash.shared.reportStore else { return }
        for id in store.reportIDs {
            guard let report = store.report(for: id.int64Value) else { continue }
            let raw = CrashReporter.serialize(report)
            sink(AgentLogEntry(level: "critical",
                service: Bundle.main.bundleIdentifier ?? "app",
                subsystem: "agent.crash", category: "crash",
                eventType: AgentEventType.crash.rawValue,
                sessionId: Session.id, agentAuto: true,
                message: "Crash report available",
                payload: ["report_id": .string("\(id.int64Value)"), "raw": .string(raw)]))
            store.deleteReport(with: id.int64Value)
        }
    }

    /// 测试辅助：注入一条用户异常报告（不终止进程）并立即转写进 sink，验证崩溃采集链路。
    public static func simulateAndFlush(sink: @escaping (AgentLogEntry) -> Void) {
        KSCrash.shared.reportUserException(
            "TestException", reason: "injected by test",
            language: "swift", lineOfCode: nil, stackTrace: nil,
            logAllThreads: false, terminateProgram: false)
        CrashReporter.flushPendingReports(sink: sink)
    }

    /// 把 KSCrash 报告尽力序列化为可读字符串（不依赖具体类型枚举，按运行时值类型兜底）。
    /// 注意：KSCrash 2.x 的 CrashReport 协议仅有 untypedValue（id?），value 只在具体子类上。
    private static func serialize(_ report: CrashReport) -> String {
        let v = report.untypedValue
        if let dict = v as? [String: Any] {
            return (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(dict)"
        } else if let data = v as? Data {
            return String(data: data, encoding: .utf8) ?? "\(data)"
        } else if let str = v as? String {
            return str
        }
        return "\(v ?? "")"
    }
}

#else
/// 未接入 KSCrash 时的降级实现：崩溃采集关闭，框架其余能力正常。
public enum CrashReporter {
    public static func install(sink: @escaping (AgentLogEntry) -> Void) {
        // no-op：消费者未引入 KSCrashInstallations
    }
}
#endif
