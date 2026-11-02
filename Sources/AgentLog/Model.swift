import Foundation

/// 一次会话（= 一次 App 启动）的稳定标识，用于把同一次运行的日志聚合。
public enum Session {
    public static let id = UUID().uuidString
}

/// 自动埋点事件类型。与 ai-dev-spec/packages/observability 的 event 概念对齐。
public enum AgentEventType: String, Codable, Sendable {
    case screenView = "screen_view"
    case uiInteraction = "ui_interaction"
    case networkRequest = "network_request"
    case crash
    case hang
    case log
}

/// 结构化值，支持字面量便于 payload 书写：`["code": 404, "msg": "x"]`。
public enum AgentValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: AgentValue])
    case array([AgentValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: AgentValue].self) { self = .object(v); return }
        if let v = try? c.decode([AgentValue].self) { self = .array(v); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

extension AgentValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension AgentValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension AgentValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension AgentValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension AgentValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, AgentValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
extension AgentValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: AgentValue...) { self = .array(elements) }
}
extension AgentValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        case .null: return "null"
        case .object, .array:
            let enc = JSONEncoder()
            guard let d = try? enc.encode(self), let s = String(data: d, encoding: .utf8) else { return "\(self)" }
            return s
        }
    }
}

/// 面向 Agent 的统一日志条目 Schema（机器可读，跨端一致）。
/// 字段对齐 Web 端 packages/observability 的 event/traceId/userId 概念。
public struct AgentLogEntry: Codable, Sendable {
    public let ts: String
    public let level: String
    public let service: String
    public let subsystem: String
    public let category: String
    public let eventType: String
    public let sessionId: String
    public let traceId: String?
    public let agentAuto: Bool
    public let message: String
    public let payload: [String: AgentValue]?

    public init(ts: String = ISO8601DateFormatter().string(from: Date()),
                level: String, service: String, subsystem: String,
                category: String, eventType: String, sessionId: String,
                traceId: String? = nil, agentAuto: Bool,
                message: String, payload: [String: AgentValue]? = nil) {
        self.ts = ts; self.level = level; self.service = service
        self.subsystem = subsystem; self.category = category
        self.eventType = eventType; self.sessionId = sessionId
        self.traceId = traceId; self.agentAuto = agentAuto
        self.message = message; self.payload = payload
    }

    /// 单行 JSON（JSONL），Agent 可直接按行读取。
    public var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
