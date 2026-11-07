import CryptoKit
import Foundation

/// OTLP 导出适配器：Schema v1 事件 → OpenTelemetry OTLP/JSON。
///
/// D3「OTel 对齐」能力：**不改线格式**，只做单向翻译，把已经写出的事件变成 OTLP，
/// 从而能通过任意 OTLP Collector 送往 Jaeger / Tempo / Loki / Datadog。
///
/// 规范真源：`docs/logging-framework/OTLP-MAPPING.md`。
/// - 每条事件 → 一条 OTLP `LogRecord`；
/// - `network_request` → 额外一条 `SPAN_KIND_CLIENT` span（HTTP 语义约定）；
/// - `db_query` → 额外一条 `SPAN_KIND_CLIENT` span（Database 语义约定）；
/// - `crash` / `hang` → 只发 logs，附 `exception.*` 属性。
///
/// 设计约束：
/// - **零第三方依赖**：产出 `AgentValue` 树，由 `JSONEncoder` 序列化；
/// - **id 确定性派生**（SHA-256，绝不随机）：同一事件重复导出得到同一组 id，重试幂等；
/// - `payload` 只**展平一层**，嵌套对象/数组保持 `kvlistValue`/`arrayValue` 结构。
///
/// 用法：
/// ```swift
/// let batch = try exporter.otlpBatch()          // {"logs": ..., "traces": ...}
/// let body = OtlpMapper.json(batch["logs"]!)    // POST 到 <collector>/v1/logs
/// ```
public enum OtlpMapper {
    /// 与项目版本保持一致（测试断言）。
    public static let sdkVersion = "1.0.0"

    /// OTel `SpanKind.SPAN_KIND_CLIENT`。
    public static let spanKindClient = 3

    /// OTel `Status.StatusCode.STATUS_CODE_ERROR`。
    public static let statusCodeError = 2

    /// 级别到 OTel logs 数据模型的翻译结果。
    public struct Severity: Equatable, Sendable {
        public let text: String
        public let number: Int

        public init(text: String, number: Int) {
            self.text = text
            self.number = number
        }
    }

    // OTel 语义约定键（部分仍为 Experimental，统一收口在这里）。
    private static let serviceName = "service.name"
    private static let deploymentEnv = "deployment.environment"
    private static let sessionIDKey = "session.id"
    private static let enduserID = "enduser.id"
    private static let httpMethod = "http.request.method"
    private static let urlFull = "url.full"
    private static let httpStatus = "http.response.status_code"
    private static let serverAddress = "server.address"
    private static let dbSystem = "db.system"
    private static let dbOperation = "db.operation"
    private static let dbStatement = "db.statement"
    private static let errorType = "error.type"
    private static let exceptionType = "exception.type"
    private static let exceptionMessage = "exception.message"
    private static let exceptionStacktrace = "exception.stacktrace"

    // agent-log 自己的属性命名空间（避免与 semconv 撞键）。
    private static let attrEventType = "agent.event.type"
    private static let attrAuto = "agent.auto"
    private static let attrSubsystem = "agent.subsystem"
    private static let attrCategory = "agent.category"

    // 操作类 span 的 payload 键候选（兼容历史写法）。
    private static let httpMethodKeys = ["method", "http_method", "http.method"]
    private static let urlKeys = ["url", "url_full", "url.full"]
    private static let statusKeys = ["status_code", "status", "statusCode", "http.status_code"]
    private static let durationKeys = ["duration_ms", "durationMs", "duration"]

    /// 规范键是 `statement`；`sql` / `query` 仅读取侧兼容旧数据（Schema v1.1）。
    private static let sqlKeys = ["statement", "sql", "query"]
    private static let dbSystemKeys = ["db_system", "db.system", "system"]
    private static let dbOperationKeys = ["operation", "op"]

    // MARK: - 值转换

    /// 转成 OTLP `AnyValue`（protobuf JSON 形式）。
    ///
    /// `int64` 必须**字符串化**：JSON 数字是 double，装不下 64 位整数。
    public static func anyValue(_ value: AgentValue) -> AgentValue {
        switch value {
        case .bool(let v):
            return .object(["boolValue": .bool(v)])
        case .int(let v):
            return .object(["intValue": .string(String(v))])
        case .double(let v):
            return .object(["doubleValue": .double(v)])
        case .string(let v):
            return .object(["stringValue": .string(v)])
        case .array(let items):
            return .object(["arrayValue": .object(["values": .array(items.map(anyValue))])])
        case .object(let map):
            return .object(["kvlistValue": .object(["values": .array(keyValues(map))])])
        case .null:
            return .object(["stringValue": .string("")])
        }
    }

    /// 构造一个 OTLP `KeyValue`。
    public static func keyValue(_ key: String, _ value: AgentValue) -> AgentValue {
        .object(["key": .string(key), "value": anyValue(value)])
    }

    /// 把对象铺平成 `KeyValue` 列表（`.null` 跳过）。
    private static func keyValues(_ mapping: [String: AgentValue], prefix: String = "") -> [AgentValue] {
        // 排序保证输出稳定（Swift Dictionary 无序），便于跨端逐字比对。
        mapping.keys.sorted().compactMap { key in
            guard let value = mapping[key], value != .null else { return nil }
            return keyValue(prefix + key, value)
        }
    }

    // MARK: - 时间

    /// RFC3339 / ISO8601 → epoch 纳秒。
    ///
    /// 超过纳秒的精度直接截断（不四舍五入）；无偏移的时间戳按 UTC 处理。
    /// 手写解析而不是用 `ISO8601DateFormatter`：后者不接受 `+0800`（无冒号）与
    /// 空格分隔的变体，而各端产出的 `ts` 这些形式都可能出现。
    public static func parseTimestampNanos(_ ts: String) throws -> Int64 {
        let trimmed = ts.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard chars.count >= 19 else {
            throw OtlpError.invalidTimestamp(ts)
        }
        func digits(_ range: Range<Int>) throws -> Int {
            var value = 0
            for index in range {
                guard let digit = chars[index].wholeNumberValue else {
                    throw OtlpError.invalidTimestamp(ts)
                }
                value = value * 10 + digit
            }
            return value
        }

        let year = try digits(0..<4)
        guard chars[4] == "-", chars[7] == "-" else { throw OtlpError.invalidTimestamp(ts) }
        let month = try digits(5..<7)
        let day = try digits(8..<10)
        guard chars[10] == "T" || chars[10] == " " else { throw OtlpError.invalidTimestamp(ts) }
        let hour = try digits(11..<13)
        guard chars[13] == ":" else { throw OtlpError.invalidTimestamp(ts) }
        let minute = try digits(14..<16)
        guard chars[16] == ":" else { throw OtlpError.invalidTimestamp(ts) }
        let second = try digits(17..<19)

        var cursor = 19
        var nanos: Int64 = 0
        if cursor < chars.count, chars[cursor] == "." {
            cursor += 1
            var fraction = ""
            while cursor < chars.count, chars[cursor].isNumber {
                fraction.append(chars[cursor])
                cursor += 1
            }
            let padded = fraction.padding(toLength: 9, withPad: "0", startingAt: 0)
            nanos = Int64(padded.prefix(9)) ?? 0
        }

        var offsetSeconds = 0
        if cursor < chars.count {
            let rest = String(chars[cursor...])
            if rest == "Z" || rest == "z" {
                offsetSeconds = 0
            } else {
                let sign = rest.hasPrefix("-") ? -1 : 1
                let body = rest.dropFirst().replacingOccurrences(of: ":", with: "")
                guard body.count >= 2, let hours = Int(body.prefix(2)) else {
                    throw OtlpError.invalidTimestamp(ts)
                }
                let minutes = body.count >= 4 ? Int(body.dropFirst(2).prefix(2)) ?? 0 : 0
                offsetSeconds = sign * (hours * 3600 + minutes * 60)
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: components) else {
            throw OtlpError.invalidTimestamp(ts)
        }
        let wallSeconds = Int64(date.timeIntervalSince1970.rounded())
        return (wallSeconds - Int64(offsetSeconds)) * 1_000_000_000 + nanos
    }

    // MARK: - id

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 事件的 OTLP `traceId`（32 位 hex），无 `trace_id` 时返回 `nil`。
    ///
    /// 32 位 hex 原样（转小写）使用；其他字符串按 `sha256("agentlog:trace:" + raw)`
    /// 确定性派生，保证共享同一逻辑 trace 的事件落进同一条 OTLP trace。
    public static func traceIDHex(_ entry: AgentLogEntry) -> String? {
        guard let raw = entry.traceId, !raw.isEmpty else { return nil }
        let isHex32 = raw.count == 32 && raw.allSatisfy { $0.isHexDigit }
        return isHex32 ? raw.lowercased() : String(sha256Hex("agentlog:trace:" + raw).prefix(32))
    }

    /// 事件的 OTLP `spanId`（16 位 hex）。
    ///
    /// Schema v1.1 的 `span_id` 合法时**优先透传**（日志行与链路节点指向同一个真实 span）；
    /// 缺失或非法时确定性派生。
    public static func spanIDHex(_ entry: AgentLogEntry) -> String {
        if let explicit = SpanIdentifier.normalize(entry.spanId) {
            return explicit
        }
        let seed = [
            "agentlog:span",
            entry.sessionId,
            entry.traceId ?? "",
            entry.eventType,
            entry.ts,
            entry.message,
        ].joined(separator: "|")
        return String(sha256Hex(seed).prefix(16))
    }

    /// span 的 trace id：无 `trace_id` 时回退到会话级合成 trace。
    ///
    /// span 不能脱离 trace 存在；同一会话的多个 span 归入同一条合成 trace，
    /// 否则在 Jaeger 里会变成一堆孤立单 span 链路。
    public static func spanTraceID(_ entry: AgentLogEntry) -> String {
        if let resolved = traceIDHex(entry) {
            return resolved
        }
        return String(sha256Hex("agentlog:session:" + entry.sessionId).prefix(32))
    }

    // MARK: - 级别

    /// agent-log level → `severityText` / `severityNumber`。
    ///
    /// 读取侧别名 `warning` 归一化为 `warn`；未知 level **降级为 INFO**，
    /// 不让一次导出因为脏数据整体失败。
    public static func levelToSeverity(_ level: String) -> Severity {
        let raw = level.lowercased()
        switch raw == "warning" ? "warn" : raw {
        case "trace": return Severity(text: "TRACE", number: 1)
        case "debug": return Severity(text: "DEBUG", number: 5)
        case "warn": return Severity(text: "WARN", number: 13)
        case "error": return Severity(text: "ERROR", number: 17)
        case "critical", "fatal": return Severity(text: "FATAL", number: 21)
        default: return Severity(text: "INFO", number: 9)
        }
    }

    // MARK: - resource

    private static func scope() -> AgentValue {
        .object(["name": .string("agentlog.otlp"), "version": .string(sdkVersion)])
    }

    private static func resourceAttributes(_ entry: AgentLogEntry) -> [AgentValue] {
        var attrs: [AgentValue] = [
            keyValue(serviceName, .string(entry.service.isEmpty ? "app" : entry.service)),
        ]
        if let env = entry.env, !env.isEmpty {
            attrs.append(keyValue(deploymentEnv, .string(env)))
        }
        if !entry.sessionId.isEmpty {
            attrs.append(keyValue(sessionIDKey, .string(entry.sessionId)))
        }
        attrs.append(keyValue("telemetry.sdk.name", .string("agent-log")))
        attrs.append(keyValue("telemetry.sdk.language", .string("swift")))
        attrs.append(keyValue("telemetry.sdk.version", .string(sdkVersion)))
        return attrs
    }

    /// 按 (service, env, session_id) 分组，保持输入顺序。
    private static func groupByResource(_ entries: [AgentLogEntry]) -> [[AgentLogEntry]] {
        var order: [String] = []
        var groups: [String: [AgentLogEntry]] = [:]
        for entry in entries {
            let key = "\(entry.service)\u{0}\(entry.env ?? "")\u{0}\(entry.sessionId)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = []
            }
            groups[key]?.append(entry)
        }
        return order.compactMap { groups[$0] }
    }

    /// 追加调用方资源属性，但**跳过 agent-log 已占用的键**。
    ///
    /// OTLP 里重复键由后端随意裁决（通常后者胜），所以「自身字段优先」必须在这里
    /// 靠直接丢弃冲突键来保证。
    private static func merge(_ resource: [AgentValue], with extra: [String: AgentValue]?) -> [AgentValue] {
        guard let extra, !extra.isEmpty else { return resource }
        var merged = resource
        var taken = Set(resource.compactMap(attributeKey))
        for kv in keyValues(extra) {
            guard let key = attributeKey(kv), !taken.contains(key) else { continue }
            merged.append(kv)
            taken.insert(key)
        }
        return merged
    }

    /// 取一个 `KeyValue` 的 `key` 字段。
    private static func attributeKey(_ value: AgentValue) -> String? {
        guard case .object(let map) = value, case .string(let key)? = map["key"] else { return nil }
        return key
    }

    // MARK: - LogRecord

    /// 把事件的非 resource 字段翻译成 OTLP 属性。
    public static func eventAttributes(_ entry: AgentLogEntry) -> [AgentValue] {
        var attrs: [AgentValue] = [
            keyValue(attrEventType, .string(entry.eventType)),
            keyValue(attrAuto, .bool(entry.agentAuto)),
        ]
        if !entry.subsystem.isEmpty {
            attrs.append(keyValue(attrSubsystem, .string(entry.subsystem)))
        }
        if !entry.category.isEmpty {
            attrs.append(keyValue(attrCategory, .string(entry.category)))
        }
        // 只放间接标识 —— Schema v1 禁止在这里放直接 PII。
        if let userId = entry.userId, !userId.isEmpty {
            attrs.append(keyValue(enduserID, .string(userId)))
        }
        let payload = entry.payload ?? [:]
        attrs.append(contentsOf: keyValues(payload, prefix: "payload."))
        if entry.eventType == "crash" || entry.eventType == "hang" {
            attrs.append(contentsOf: exceptionAttributes(payload))
        }
        return attrs
    }

    private static func exceptionAttributes(_ payload: [String: AgentValue]) -> [AgentValue] {
        var attrs: [AgentValue] = []
        if let excType = first(payload, ["exception", "exception_type"]) {
            attrs.append(keyValue(exceptionType, excType))
        }
        // crash 的 payload 用 `message` 装异常文本；两种写法都认。
        if let excMessage = first(payload, ["exception_message", "message"]) {
            attrs.append(keyValue(exceptionMessage, excMessage))
        }
        if let stack = first(payload, ["stack", "stacktrace", "trace"]) {
            attrs.append(keyValue(exceptionStacktrace, stack))
        }
        return attrs
    }

    /// 一条 Schema v1 事件 → 一条 OTLP `LogRecord`。
    public static func logRecord(for entry: AgentLogEntry) throws -> AgentValue {
        let severity = levelToSeverity(entry.level)
        let time = String(try parseTimestampNanos(entry.ts))

        var fields: [String: AgentValue] = [
            "timeUnixNano": .string(time),
            "observedTimeUnixNano": .string(time),
            "severityNumber": .int(severity.number),
            "severityText": .string(severity.text),
            "body": .object(["stringValue": .string(entry.message)]),
            "attributes": .array(eventAttributes(entry)),
        ]

        if let traceId = traceIDHex(entry) {
            fields["traceId"] = .string(traceId)
            // 优先用事件自带的（v1.1）span id —— 它指向真实 span。否则只给操作类事件配 id，
            // 与它产出的 span 对齐，日志行永远不会引用一个不存在的 span。
            if let explicit = SpanIdentifier.normalize(entry.spanId) {
                fields["spanId"] = .string(explicit)
            } else if spanKind(entry) != nil {
                fields["spanId"] = .string(spanIDHex(entry))
            }
        }
        return .object(fields)
    }

    // MARK: - Span

    private static func first(_ payload: [String: AgentValue], _ keys: [String]) -> AgentValue? {
        for key in keys {
            guard let value = payload[key], value != .null else { continue }
            if case .string(let text) = value, text.isEmpty { continue }
            return value
        }
        return nil
    }

    private static func text(_ payload: [String: AgentValue], _ keys: [String]) -> String? {
        guard let value = first(payload, keys) else { return nil }
        switch value {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        default: return nil
        }
    }

    private static func number(_ value: AgentValue?) -> Double? {
        switch value {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Double(v)
        default: return nil
        }
    }

    private static func durationMs(_ payload: [String: AgentValue]) -> Double {
        number(first(payload, durationKeys)) ?? 0
    }

    /// 只有 `network_request` / `db_query` 是「调用跨度」。
    private static func spanKind(_ entry: AgentLogEntry) -> Int? {
        entry.eventType == "network_request" || entry.eventType == "db_query" ? spanKindClient : nil
    }

    private static func httpSpanName(_ payload: [String: AgentValue]) -> String {
        let method = text(payload, httpMethodKeys) ?? "HTTP"
        let url = text(payload, urlKeys) ?? ""
        return "\(method) \(url)"
    }

    private static func httpError(_ payload: [String: AgentValue], status: Double?) -> String? {
        if let status, status >= 400 {
            return String(Int64(status))
        }
        guard let raw = text(payload, ["error"]), !raw.isEmpty else { return nil }
        return raw
    }

    private static func httpSpanAttributes(_ payload: [String: AgentValue]) -> [AgentValue] {
        var attrs: [AgentValue] = []
        if let method = text(payload, httpMethodKeys) {
            attrs.append(keyValue(httpMethod, .string(method)))
        }
        if let url = text(payload, urlKeys) {
            attrs.append(keyValue(urlFull, .string(url)))
            if let host = hostOf(url) {
                attrs.append(keyValue(serverAddress, .string(host)))
            }
        }
        // 状态码是整数：始终 intValue，即使 payload 里写成 200.0。
        if let status = number(first(payload, statusKeys)) {
            attrs.append(keyValue(httpStatus, .int(Int(status))))
        }
        if let error = httpError(payload, status: number(first(payload, statusKeys))) {
            attrs.append(keyValue(errorType, .string(error)))
        }
        return attrs
    }

    /// 取绝对 URL 的 host 部分（`server.address`）。
    private static func hostOf(_ url: String) -> String? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let scheme = url[url.startIndex..<schemeRange.lowerBound]
        guard let firstChar = scheme.first, firstChar.isLetter else { return nil }
        var hostPort = url[schemeRange.upperBound...]
        if let cut = hostPort.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            hostPort = hostPort[..<cut]
        }
        if let at = hostPort.lastIndex(of: "@") {
            hostPort = hostPort[hostPort.index(after: at)...]
        }
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return String(hostPort) }
            return String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
        }
        if let colon = hostPort.firstIndex(of: ":") {
            return String(hostPort[..<colon])
        }
        return String(hostPort)
    }

    private static func dbSpanName(_ payload: [String: AgentValue]) -> String {
        let operation = text(payload, dbOperationKeys) ?? "SQL"
        let statement = text(payload, sqlKeys) ?? ""
        return "\(operation) \(statement)"
    }

    private static func dbError(_ payload: [String: AgentValue]) -> String? {
        if let raw = text(payload, ["error"]), !raw.isEmpty { return raw }
        if let raw = text(payload, ["error_type"]), !raw.isEmpty { return raw }
        return nil
    }

    private static func dbSpanAttributes(_ payload: [String: AgentValue]) -> [AgentValue] {
        var attrs: [AgentValue] = []
        if let system = text(payload, dbSystemKeys) {
            attrs.append(keyValue(dbSystem, .string(system)))
        }
        if let operation = text(payload, dbOperationKeys) {
            attrs.append(keyValue(dbOperation, .string(operation)))
        }
        if let statement = text(payload, sqlKeys) {
            attrs.append(keyValue(dbStatement, .string(statement)))
        }
        if let error = dbError(payload) {
            attrs.append(keyValue(errorType, .string(error)))
        }
        return attrs
    }

    /// 一条操作事件 → 一条 OTLP `Span`；非操作事件返回 `nil`。
    public static func span(for entry: AgentLogEntry) throws -> AgentValue? {
        guard let kind = spanKind(entry) else { return nil }
        let payload = entry.payload ?? [:]
        let isHTTP = entry.eventType == "network_request"
        let name = isHTTP ? httpSpanName(payload) : dbSpanName(payload)
        let attributes = isHTTP ? httpSpanAttributes(payload) : dbSpanAttributes(payload)
        let failed = isHTTP
            ? httpError(payload, status: number(first(payload, statusKeys))) != nil
            : dbError(payload) != nil

        let start = try parseTimestampNanos(entry.ts)
        let end = start + Int64((durationMs(payload) * 1_000_000).rounded())

        var fields: [String: AgentValue] = [
            "traceId": .string(spanTraceID(entry)),
            "spanId": .string(spanIDHex(entry)),
            "name": .string(name),
            "kind": .int(kind),
            "startTimeUnixNano": .string(String(start)),
            "endTimeUnixNano": .string(String(end)),
            "attributes": .array(attributes),
        ]
        if failed {
            fields["status"] = .object(["code": .int(statusCodeError), "message": .string(name)])
        }
        return .object(fields)
    }

    // MARK: - 批次

    /// 构造 OTLP/JSON `ExportLogsServiceRequest`。
    public static func toOtlpLogs(
        _ entries: [AgentLogEntry],
        extraResource: [String: AgentValue]? = nil
    ) throws -> AgentValue {
        var resourceLogs: [AgentValue] = []
        for group in groupByResource(entries) {
            guard let head = group.first else { continue }
            let records = try group.map { try logRecord(for: $0) }
            resourceLogs.append(.object([
                "resource": .object(["attributes": .array(merge(resourceAttributes(head), with: extraResource))]),
                "scopeLogs": .array([.object([
                    "scope": scope(),
                    "logRecords": .array(records),
                ])]),
            ]))
        }
        return .object(["resourceLogs": .array(resourceLogs)])
    }

    /// 构造 OTLP/JSON `ExportTraceServiceRequest`。
    public static func toOtlpSpans(
        _ entries: [AgentLogEntry],
        extraResource: [String: AgentValue]? = nil
    ) throws -> AgentValue {
        var resourceSpans: [AgentValue] = []
        for group in groupByResource(entries) {
            guard let head = group.first else { continue }
            let spans = try group.compactMap { try span(for: $0) }
            // 没有操作事件：整组跳过，而不是发一个空的 resource 块（以及一个空请求）。
            if spans.isEmpty { continue }
            resourceSpans.append(.object([
                "resource": .object(["attributes": .array(merge(resourceAttributes(head), with: extraResource))]),
                "scopeSpans": .array([.object([
                    "scope": scope(),
                    "spans": .array(spans),
                ])]),
            ]))
        }
        return .object(["resourceSpans": .array(resourceSpans)])
    }

    /// 一次产出两种信号。
    ///
    /// OTLP 一次请求只承载一种信号：`logs` POST 到 `/v1/logs`，`traces` POST 到 `/v1/traces`。
    public static func toOtlp(
        _ entries: [AgentLogEntry],
        extraResource: [String: AgentValue]? = nil
    ) throws -> AgentValue {
        .object([
            "logs": try toOtlpLogs(entries, extraResource: extraResource),
            "traces": try toOtlpSpans(entries, extraResource: extraResource),
        ])
    }

    /// 序列化为 JSON 文本（键排序，输出稳定）。
    public static func json(_ payload: AgentValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// OTLP 适配器的错误类型。
public enum OtlpError: Error, CustomStringConvertible {
    case invalidTimestamp(String)

    public var description: String {
        switch self {
        case .invalidTimestamp(let ts): return "not an RFC3339 timestamp: \(ts)"
        }
    }
}

extension AgentLogExporter {
    /// 把当前 JSONL 里的全部条目翻译成一个 OTLP 批次（`{"logs": ..., "traces": ...}`）。
    public func otlpBatch(extraResource: [String: AgentValue]? = nil) throws -> AgentValue {
        try OtlpMapper.toOtlp(loadEntries(), extraResource: extraResource)
    }
}
