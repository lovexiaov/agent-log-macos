import Foundation

/// 一次会话（= 一次 App 启动）的稳定标识，用于把同一次运行的日志聚合。
public enum Session {
    public static let id = UUID().uuidString
}

/// 自动埋点事件类型。与 Web 端（agent-log-web）的 event_type 概念对齐。
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

/// Schema v1.1 span id：16 位小写 hex，与 W3C `traceparent` 的 span-id 同构。
///
/// 非法值返回 `nil` —— 调用方**丢弃而不是写出**，坏值永远不会产出违规行。
public enum SpanIdentifier {
    public static func normalize(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.count == 16 else { return nil }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard trimmed.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        return trimmed.lowercased()
    }
}

/// 面向 Agent 的统一日志条目 —— Schema v1 线格式（snake_case）。
///
/// 规范真源：ai-dev-spec `docs/logging-framework/schema/log-event.schema.json`。
/// Swift 侧属性名保持 camelCase，**仅在序列化边界**通过 `CodingKeys` 映射为 snake_case；
/// 顶层字段集封闭，业务自定义字段一律进 `payload`。
public struct AgentLogEntry: Codable, Sendable {
    public let ts: String
    public let level: String
    public let service: String
    public let subsystem: String
    public let category: String
    public let eventType: String
    public let sessionId: String
    public let traceId: String?
    public let spanId: String?
    public let agentAuto: Bool
    public let message: String
    public let env: String?
    /// 间接用户标识（Schema v1 的可选 `user_id`；禁止直接 PII）。
    ///
    /// 其余五端（Python/Go/Java/Kotlin/Web）早已支持；Swift 侧此前缺失，
    /// 导致 OTLP 适配器无法产出 `enduser.id`，Schema v1.1 阶段补齐。
    public let userId: String?
    public let payload: [String: AgentValue]?

    public enum CodingKeys: String, CodingKey {
        case ts, level, service, subsystem, category, message, payload, env
        case eventType = "event_type"
        case sessionId = "session_id"
        case traceId = "trace_id"
        case spanId = "span_id"
        case userId = "user_id"
        case agentAuto = "agent_auto"
    }

    public init(ts: String = ISO8601DateFormatter().string(from: Date()),
                level: String, service: String, subsystem: String,
                category: String, eventType: String, sessionId: String,
                traceId: String? = nil, spanId: String? = nil, agentAuto: Bool,
                message: String, env: String? = nil, userId: String? = nil,
                payload: [String: AgentValue]? = nil) {
        self.ts = ts; self.level = level; self.service = service
        self.subsystem = subsystem; self.category = category
        self.eventType = eventType; self.sessionId = sessionId
        self.traceId = traceId
        // 序列化边界统一校验：即使直接构造 Entry，也不会写出非法 span_id。
        self.spanId = SpanIdentifier.normalize(spanId)
        self.agentAuto = agentAuto
        self.message = message; self.env = env
        self.userId = userId
        self.payload = payload
    }

    /// 单行 JSON（JSONL），Agent 可直接按行读取。
    public var jsonLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
