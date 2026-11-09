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
    /// - Parameters:
    ///   - sink: 接收结构化条目的回调（通常为 `AgentLog.appendRaw`）。
    ///   - release: Schema v1.3 的 `release`，由 `AgentLogConfig` 下传并盖章到崩溃事件。
    public static func install(sink: @escaping (AgentLogEntry) -> Void,
                               release: String? = nil) {
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
                message: "KSCrash install failed: \(error.localizedDescription)",
                env: AgentLogConfig.defaultEnv, release: release))
            return
        }

        // 启动时把上次遗留的崩溃报告转成结构化条目
        CrashReporter.flushPendingReports(sink: sink, release: release)
    }

    /// 读取并转写 `KSCrash.reportStore` 中所有遗留报告进 sink（不重新 install KSCrash）。
    /// 供 `install` 启动时扫描，以及测试时二次触发。
    public static func flushPendingReports(sink: @escaping (AgentLogEntry) -> Void,
                                          release: String? = nil) {
        guard let store = KSCrash.shared.reportStore else { return }
        for id in store.reportIDs {
            guard let report = store.report(for: id.int64Value) else { continue }
            let dictionary = CrashReporter.dictionary(report)
            var payload: [String: AgentValue] = [
                "report_id": .string("\(id.int64Value)"),
                "raw": .string(CrashReporter.serialize(report, dictionary: dictionary)),
            ]
            if let dictionary {
                // 标准键优先；解析不出来也不影响本次崩溃事件（`raw` 兜底）。
                for (key, value) in CrashReporter.standardPayload(from: dictionary) {
                    payload[key] = value
                }
            }
            sink(AgentLogEntry(level: "critical",
                service: Bundle.main.bundleIdentifier ?? "app",
                subsystem: "agent.crash", category: "crash",
                eventType: AgentEventType.crash.rawValue,
                sessionId: Session.id, agentAuto: true,
                message: "Crash report available",
                env: AgentLogConfig.defaultEnv, release: release,
                payload: payload))
            store.deleteReport(with: id.int64Value)
        }
    }

    /// 测试辅助：注入一条用户异常报告（不终止进程）并立即转写进 sink，验证崩溃采集链路。
    public static func simulateAndFlush(sink: @escaping (AgentLogEntry) -> Void,
                                        release: String? = nil) {
        KSCrash.shared.reportUserException(
            "TestException", reason: "injected by test",
            language: "swift", lineOfCode: nil, stackTrace: nil,
            logAllThreads: false, terminateProgram: false)
        CrashReporter.flushPendingReports(sink: sink, release: release)
    }

    // MARK: - 标准异常词表（best-effort）

    /// 从 KSCrash 报告里尽力提取标准异常词表：`exception` / `exception_message` /
    /// `stack` / `mechanism`（+ `thread`）。
    ///
    /// 契约见 `docs/logging-framework/INTERFACE.md`。KSCrash 的报告结构随版本演进，
    /// 这里**只认明确存在的键**、取不到就不写——崩溃事件的完整性优先于字段完备，
    /// 解析失败绝不抛错，`raw` 始终兜底。
    ///
    /// `mechanism`：宿主主动上报（`user.user_exception`）记 `reported`，
    /// 其余一律 `uncaught`（与其余五端同一词表）。
    static func standardPayload(from report: [String: Any]) -> [String: AgentValue] {
        var payload: [String: AgentValue] = [:]
        let crash = report["crash"] as? [String: Any]
        let error = crash?["error"] as? [String: Any]
        let nsException = error?["nsexception"] as? [String: Any]
        let cppException = error?["cpp_exception"] as? [String: Any]
        let signal = error?["signal"] as? [String: Any]
        let machException = error?["mach_exception"] as? [String: Any]
        // 宿主主动上报：新版本写在 `crash.error.user_reported`，旧图纸/其它实现写在
        // 顶层 `user.user_exception`。两种形态都认，取到即视为 reported。
        let userReported = (error?["user_reported"] as? [String: Any])
            ?? (report["user"] as? [String: Any])?["user_exception"] as? [String: Any]
        let isUserReported = userReported != nil || text(error?["type"]) == "user"

        // 异常类型：具体类型名优先，逐级退到信号名 / mach 异常名 / 报告级 type。
        if let name = text(nsException?["name"])
            ?? text(cppException?["name"])
            ?? text(userReported?["name"])
            ?? text(signal?["name"])
            ?? text(machException?["exception_name"])
            ?? text(error?["type"]) {
            payload["exception"] = .string(name)
        }
        if let message = text(nsException?["reason"])
            ?? text(cppException?["reason"])
            ?? text(userReported?["reason"])
            ?? text(error?["reason"]) {
            payload["exception_message"] = .string(message)
        }

        if let thread = crashedThread(in: crash) {
            if let trace = formatStack(thread) {
                payload["stack"] = .string(trace)
            }
            if let label = threadLabel(thread) {
                payload["thread"] = .string(label)
            }
        }

        payload["mechanism"] = .string(isUserReported ? "reported" : "uncaught")
        return payload
    }

    /// 崩溃线程：优先 `crashed == true`，退化到 `crashed_thread.index`（旧格式）。
    private static func crashedThread(in crash: [String: Any]?) -> [String: Any]? {
        let threads = crash?["threads"] as? [[String: Any]] ?? []
        if let crashed = threads.first(where: { ($0["crashed"] as? Bool) == true }) {
            return crashed
        }
        if let index = crash?["crashed_thread"] as? [String: Any],
           let position = index["index"] as? Int,
           position >= 0, position < threads.count {
            return threads[position]
        }
        return threads.first
    }

    /// 线程标签：`name` → `queue_name` → `thread #<index>`。
    private static func threadLabel(_ thread: [String: Any]) -> String? {
        if let name = text(thread["name"]) { return name }
        if let queue = text(thread["queue_name"]) { return "queue:\(queue)" }
        if let index = thread["index"] as? Int { return "thread #\(index)" }
        return nil
    }

    /// 把调用栈格式化为**单字符串**（契约：`stack` 不结构化 frames，下游自行解析）。
    ///
    /// 帧数组的键在 KSCrash 各版本间叫 `backtrace` / `contents`；宿主自报的栈
    /// （`reportUserException(stackTrace:)`）可能直接是字符串数组，两者都接受。
    private static func formatStack(_ thread: [String: Any]) -> String? {
        let raw = thread["backtrace"] ?? thread["contents"]
        if let lines = raw as? [String], !lines.isEmpty {
            return lines.joined(separator: "\n")
        }
        let frames = (raw as? [[String: Any]]) ?? []
        guard !frames.isEmpty else { return nil }
        var lines: [String] = []
        for (offset, frame) in frames.enumerated() {
            let symbol = text(frame["symbol_name"]) ?? "<unknown>"
            let image = text(frame["object_name"]) ?? ""
            lines.append(image.isEmpty ? "\(offset)   \(symbol)" : "\(offset)   \(image)   \(symbol)")
        }
        return lines.joined(separator: "\n")
    }

    /// 只接受非空字符串（KSCrash 里同名字段可能是 NSNull 或数字）。
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 序列化

    /// 取报告的字典形式（`raw` 兜底与标准词表解析共用一份，避免二次序列化）。
    private static func dictionary(_ report: CrashReport) -> [String: Any]? {
        let value = report.untypedValue
        if let dictionary = value as? [String: Any] { return dictionary }
        if let data = value as? Data,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    /// 把 KSCrash 报告尽力序列化为可读字符串（不依赖具体类型枚举，按运行时值类型兜底）。
    /// 注意：KSCrash 2.x 的 CrashReport 协议仅有 untypedValue（id?），value 只在具体子类上。
    private static func serialize(_ report: CrashReport, dictionary: [String: Any]?) -> String {
        if let dictionary,
           let data = try? JSONSerialization.data(withJSONObject: dictionary, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        let value = report.untypedValue
        if let data = value as? Data {
            return String(data: data, encoding: .utf8) ?? "\(data)"
        } else if let string = value as? String {
            return string
        }
        return "\(value ?? "")"
    }
}

#else
/// 未接入 KSCrash 时的降级实现：崩溃采集关闭，框架其余能力正常。
public enum CrashReporter {
    public static func install(sink: @escaping (AgentLogEntry) -> Void,
                               release: String? = nil) {
        // no-op：消费者未引入 KSCrashInstallations
    }
}
#endif
