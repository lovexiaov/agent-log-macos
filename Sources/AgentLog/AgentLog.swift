import Foundation
import Logging
import Pulse

// MARK: - 配置

public struct AgentLogConfig {
    public var subsystem: String
    public var service: String
    public var autoInstrumentation: AutoInstrumentationOptions
    public var redactSensitive: Bool
    public var exportDirectory: URL?
    public var minLevel: Level

    public enum Level: Sendable {
        case trace, debug, info, warning, error
        public var loggerLevel: Logging.Logger.Level {
            switch self {
            case .trace: return .trace
            case .debug: return .debug
            case .info: return .info
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    public init(subsystem: String, service: String? = nil,
                autoInstrumentation: AutoInstrumentationOptions = .all,
                redactSensitive: Bool = true,
                exportDirectory: URL? = nil,
                minLevel: Level = .debug) {
        self.subsystem = subsystem
        self.service = service ?? Bundle.main.bundleIdentifier ?? "app"
        self.autoInstrumentation = autoInstrumentation
        self.redactSensitive = redactSensitive
        self.exportDirectory = exportDirectory
        self.minLevel = minLevel
    }

    public static func `default`(subsystem: String) -> AgentLogConfig {
        AgentLogConfig(subsystem: subsystem)
    }
}

public struct AutoInstrumentationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let screenView   = AutoInstrumentationOptions(rawValue: 1 << 0)
    public static let uiInteraction = AutoInstrumentationOptions(rawValue: 1 << 1)
    public static let network      = AutoInstrumentationOptions(rawValue: 1 << 2)
    public static let crash        = AutoInstrumentationOptions(rawValue: 1 << 3)
    public static let hang         = AutoInstrumentationOptions(rawValue: 1 << 4)
    public static let all: AutoInstrumentationOptions = [.screenView, .uiInteraction, .network, .crash, .hang]
}

// MARK: - 线程安全 JSONL 文件 sink

/// 直接落盘 JSONL，面向 Agent；不经过 swift-log handler，避免依赖其格式化。
final class FileSink {
    private let lock = NSLock()
    private let fileURL: URL
    private var handle: FileHandle?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        try? handle?.seekToEnd()
    }

    func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        handle?.write(data)
    }

    var url: URL { fileURL }
}

extension Logging.Logger.Level {
    var agentName: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info, .notice: return "info"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        @unknown default: return "info"
        }
    }
    init?(agentName: String) {
        switch agentName {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "warning": self = .warning
        case "error": self = .error
        case "critical": self = .critical
        default: return nil
        }
    }
}

// MARK: - 主入口

public final class AgentLog {
    public static var shared: AgentLog!

    private let config: AgentLogConfig
    private let fileSink: FileSink
    private let redactor: Redactor
    private let pulseLogger: Logging.Logger

    private static let bootstrapLock = NSLock()
    private static var pulseBootstrapped = false

    private init(config: AgentLogConfig) {
        self.config = config
        self.redactor = Redactor()

        // 1. 初始化 Pulse 作为结构化存储（仅一次）
        Self.bootstrapLock.lock()
        if !Self.pulseBootstrapped {
            LoggingSystem.bootstrap(PersistentLogHandler.init)
            Self.pulseBootstrapped = true
        }
        Self.bootstrapLock.unlock()

        // 2. 初始化 JSONL 文件 sink（面向 Agent 的主要消费源）
        let dir = config.exportDirectory ?? Self.defaultExportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-log.jsonl")
        self.fileSink = FileSink(fileURL: file)

        // 3. Pulse logger（供人在 Pulse macOS 查看器查看）
        self.pulseLogger = Logging.Logger(label: config.subsystem)
    }

    /// 业务入口：一处调用，自动埋点默认全开。务必在 App 启动最早处调用。
    public static func bootstrap(subsystem: String = "com.yourapp.agent",
                                 config: AgentLogConfig? = nil) {
        let cfg = config ?? AgentLogConfig(subsystem: subsystem)
        let inst = AgentLog(config: cfg)
        shared = inst
        inst.installAuto()
    }

    private func installAuto() {
        if config.autoInstrumentation.contains(.crash) {
            CrashReporter.install { [weak self] entry in self?.appendRaw(entry) }
        }
        AutoInstrumentation.install(config: config)
    }

    // MARK: - 业务手动日志（agent_auto = false）

    public static func trace(_ message: String, category: String = "app", traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        shared?.record(level: .trace, message, category: category, traceId: traceId, eventType: .log, payload: payload)
    }
    public static func debug(_ message: String, category: String = "app", traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        shared?.record(level: .debug, message, category: category, traceId: traceId, eventType: .log, payload: payload)
    }
    public static func info(_ message: String, category: String = "app", traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        shared?.record(level: .info, message, category: category, traceId: traceId, eventType: .log, payload: payload)
    }
    public static func warning(_ message: String, category: String = "app", traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        shared?.record(level: .warning, message, category: category, traceId: traceId, eventType: .log, payload: payload)
    }
    public static func error(_ message: String, category: String = "app", traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        shared?.record(level: .error, message, category: category, traceId: traceId, eventType: .log, payload: payload)
    }

    // MARK: - 自动埋点内部回调（agent_auto = true）

    func recordAuto(eventType: AgentEventType, message: String, category: String = "auto",
                    traceId: String? = nil, payload: [String: AgentValue]? = nil) {
        record(level: .info, message, category: category, traceId: traceId, eventType: eventType, payload: payload)
    }

    private func record(level: Logging.Logger.Level, _ message: String, category: String,
                        traceId: String?, eventType: AgentEventType, payload: [String: AgentValue]?) {
        guard level >= config.minLevel.loggerLevel else { return }
        let cleanMessage = config.redactSensitive ? redactor.redact(message) : message
        let cleanPayload = config.redactSensitive ? redactor.maskSensitiveKeys(payload ?? [:]) : payload
        let entry = AgentLogEntry(
            level: level.agentName, service: config.service, subsystem: config.subsystem,
            category: category, eventType: eventType.rawValue, sessionId: Session.id,
            traceId: traceId, agentAuto: eventType != .log, message: cleanMessage,
            payload: cleanPayload.isEmpty ? nil : cleanPayload)
        appendRaw(entry)
    }

    private func appendRaw(_ entry: AgentLogEntry) {
        fileSink.append(entry.jsonLine)
        // 转发一份到 Pulse（供人在查看器查看，非 Agent 主要消费源）
        var md: Logging.Logger.Metadata = [
            "event_type": .string(entry.eventType),
            "session_id": .string(entry.sessionId),
            "agent_auto": .string(entry.agentAuto ? "true" : "false")
        ]
        if let t = entry.traceId { md["trace_id"] = .string(t) }
        if let p = entry.payload {
            for (k, v) in p where !redactor.shouldMask(key: k) {
                md["payload_\(k)"] = .string(v.description)
            }
        }
        let lvl = Logging.Logger.Level(agentName: entry.level) ?? .info
        pulseLogger.log(level: lvl, Logging.Logger.Message(stringLiteral: entry.message), metadata: md)
    }

    // MARK: - 导出

    public static func exporter() -> AgentLogExporter {
        AgentLogExporter(sourceFile: shared.fileSink.url)
    }

    public static func export(to destination: URL? = nil) throws -> URL {
        try AgentLogExporter(sourceFile: shared.fileSink.url).exportCopy(to: destination)
    }

    private static func defaultExportDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs").appendingPathComponent(Bundle.main.bundleIdentifier ?? "AgentLog")
    }
}
