import XCTest
@testable import AgentLog

/// OTLP 映射一致性：级别表、确定性 id、LogRecord 形状、HTTP/DB span 语义、
/// resource 分组与批次入口。
///
/// 每条断言都对应 `docs/logging-framework/OTLP-MAPPING.md` 的一条规则；
/// Python / Go / Java / Kotlin / Web 的测试套件断言同一组不变量，
/// 六端产出已用 `tools/otlp-compat-verify` 的样例做过逐字比对。
final class OtlpMapperTests: XCTestCase {

    private let trace = "0123456789abcdef0123456789abcdef"
    private let span = "a1b2c3d4e5f60718"
    private let ts = "2026-11-07T10:00:00.123456789Z"
    private let tsNanos: Int64 = 1_794_045_600_123_456_789

    // MARK: - 构造与取值辅助

    private func entry(
        type: String = "log",
        level: String = "info",
        message: String = "hello",
        payload: [String: AgentValue]? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        userId: String? = nil,
        env: String? = "prod",
        agentAuto: Bool = false
    ) -> AgentLogEntry {
        AgentLogEntry(
            ts: ts,
            level: level,
            service: "demo-app",
            subsystem: "com.demo",
            category: "app",
            eventType: type,
            sessionId: "sess-1",
            traceId: traceId,
            spanId: spanId,
            agentAuto: agentAuto,
            message: message,
            env: env,
            userId: userId,
            payload: payload)
    }

    private func fields(_ value: AgentValue) -> [String: AgentValue] {
        guard case .object(let map) = value else {
            XCTFail("expected an object, got \(value)")
            return [:]
        }
        return map
    }

    private func items(_ value: AgentValue?) -> [AgentValue] {
        guard case .array(let list)? = value else { return [] }
        return list
    }

    private func text(_ value: AgentValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        return text
    }

    private func number(_ value: AgentValue?) -> Int? {
        guard case .int(let value)? = value else { return nil }
        return value
    }

    private func boolean(_ value: AgentValue?) -> Bool? {
        guard case .bool(let value)? = value else { return nil }
        return value
    }

    /// 在 attributes 数组里按键取 AnyValue。
    private func attr(_ attributes: [AgentValue], _ key: String) -> AgentValue? {
        for item in attributes {
            let kv = fields(item)
            if text(kv["key"]) == key {
                return kv["value"]
            }
        }
        return nil
    }

    private func attrText(_ attributes: [AgentValue], _ key: String) -> String? {
        text(fields(attr(attributes, key) ?? .null)["stringValue"])
    }

    private func attrInt(_ attributes: [AgentValue], _ key: String) -> String? {
        text(fields(attr(attributes, key) ?? .null)["intValue"])
    }

    // MARK: - 级别

    func testSeverityTableMatchesSpec() {
        let expected: [(String, String, Int)] = [
            ("trace", "TRACE", 1),
            ("debug", "DEBUG", 5),
            ("info", "INFO", 9),
            ("warn", "WARN", 13),
            ("error", "ERROR", 17),
            ("critical", "FATAL", 21),
        ]
        for (level, text, number) in expected {
            let severity = OtlpMapper.levelToSeverity(level)
            XCTAssertEqual(severity.text, text, "severityText for \(level)")
            XCTAssertEqual(severity.number, number, "severityNumber for \(level)")
        }
    }

    func testWarningIsNotCanonicalAndUnknownLevelDegradeToInfo() {
        XCTAssertEqual(OtlpMapper.levelToSeverity("warning"), .init(text: "INFO", number: 9))
        XCTAssertEqual(OtlpMapper.levelToSeverity("nonsense"), .init(text: "INFO", number: 9))
        XCTAssertEqual(OtlpMapper.levelToSeverity(""), .init(text: "INFO", number: 9))
    }

    // MARK: - 值转换

    func testAnyValueFollowsProtoJSONMapping() {
        XCTAssertEqual(boolean(fields(OtlpMapper.anyValue(.bool(true)))["boolValue"]), true)
        // int64 必须字符串化
        XCTAssertEqual(text(fields(OtlpMapper.anyValue(.int(42)))["intValue"]), "42")
        XCTAssertEqual(text(fields(OtlpMapper.anyValue(.string("hi")))["stringValue"]), "hi")
        guard case .double(let double)? = fields(OtlpMapper.anyValue(.double(0.5)))["doubleValue"] else {
            XCTFail("expected doubleValue")
            return
        }
        XCTAssertEqual(double, 0.5, accuracy: 1e-9)
    }

    func testNestedContainersStayStructuredAndNullsAreSkipped() {
        let array = fields(OtlpMapper.anyValue(.array([.int(1), .string("two")])))
        let values = items(fields(array["arrayValue"] ?? .null)["values"])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(text(fields(values[0])["intValue"]), "1")

        let kvlist = fields(OtlpMapper.anyValue(.object(["a": .int(1), "skip": .null])))
        let kvs = items(fields(kvlist["kvlistValue"] ?? .null)["values"])
        XCTAssertEqual(kvs.count, 1, "null 值丢弃，不导出")
    }

    // MARK: - 时间

    func testTimestampParsesOffsetsAndTruncatesSubNanosecond() throws {
        let utc = try OtlpMapper.parseTimestampNanos("2026-11-07T10:00:00Z")
        XCTAssertEqual(try OtlpMapper.parseTimestampNanos("2026-11-07T18:00:00+08:00"), utc)
        XCTAssertEqual(try OtlpMapper.parseTimestampNanos("2026-11-07T18:00:00+0800"), utc)
        XCTAssertEqual(try OtlpMapper.parseTimestampNanos("2026-11-07 10:00:00"), utc)
        XCTAssertEqual(try OtlpMapper.parseTimestampNanos(ts), tsNanos)
        XCTAssertEqual(
            try OtlpMapper.parseTimestampNanos("2026-11-07T10:00:00.1234567899Z"),
            tsNanos,
            "亚纳秒位截断而非四舍五入")
    }

    func testTimestampRejectsNonRFC3339() {
        XCTAssertThrowsError(try OtlpMapper.parseTimestampNanos("not-a-time"))
    }

    // MARK: - id

    func testTraceIdPassthroughAndDropOfNonHex() {
        XCTAssertEqual(OtlpMapper.traceIDHex(entry(traceId: trace.uppercased())), trace)
        // Schema v1.2：非法值不派生、不变形，直接按无 trace 处理
        for bad in ["opaque-trace", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdez"] {
            XCTAssertNil(OtlpMapper.traceIDHex(entry(traceId: bad)), bad)
        }
        XCTAssertNil(OtlpMapper.traceIDHex(entry()))
    }

    func testTraceIdentifierHelpers() {
        // newTraceId 产出 Schema v1.2 合法的 32 位小写 hex
        let fresh = TraceIdentifier.newTraceId()
        XCTAssertEqual(fresh, TraceIdentifier.normalize(fresh))
        XCTAssertEqual(TraceIdentifier.normalize("0123456789ABCDEF0123456789ABCDEF"),
                       "0123456789abcdef0123456789abcdef")
        XCTAssertNil(TraceIdentifier.normalize("trace-abc"))
    }

    func testSpanIdPrefersExplicitValueAndIgnoresMalformedInput() {
        XCTAssertEqual(OtlpMapper.spanIDHex(entry(spanId: span.uppercased())), span)
        let derived = OtlpMapper.spanIDHex(entry())
        XCTAssertEqual(derived.count, 16)
        XCTAssertEqual(OtlpMapper.spanIDHex(entry(spanId: "not-a-span-id")), derived)
    }

    func testSpanWithoutTraceFallsBackToSessionTrace() {
        XCTAssertEqual(
            OtlpMapper.spanTraceID(entry(type: "network_request")),
            OtlpMapper.spanTraceID(entry(type: "db_query")),
            "同一会话的 span 归入同一条合成 trace")
    }

    // MARK: - LogRecord

    func testLogRecordCarriesSpecFields() throws {
        let record = fields(try OtlpMapper.logRecord(
            for: entry(
                level: "error",
                message: "boom",
                payload: ["attempt": .int(2), "ok": .bool(false)],
                traceId: trace,
                spanId: span,
                userId: "u-1")))
        XCTAssertEqual(text(record["timeUnixNano"]), "1794045600123456789")
        XCTAssertEqual(text(record["observedTimeUnixNano"]), text(record["timeUnixNano"]))
        XCTAssertEqual(number(record["severityNumber"]), 17)
        XCTAssertEqual(text(record["severityText"]), "ERROR")
        XCTAssertEqual(text(fields(record["body"] ?? .null)["stringValue"]), "boom")
        XCTAssertEqual(text(record["traceId"]), trace)
        XCTAssertEqual(text(record["spanId"]), span)

        let attrs = items(record["attributes"])
        XCTAssertEqual(attrText(attrs, "agent.event.type"), "log")
        XCTAssertEqual(boolean(fields(attr(attrs, "agent.auto") ?? .null)["boolValue"]), false)
        XCTAssertEqual(attrText(attrs, "agent.subsystem"), "com.demo")
        XCTAssertEqual(attrText(attrs, "agent.category"), "app")
        XCTAssertEqual(attrText(attrs, "enduser.id"), "u-1")
        XCTAssertEqual(attrInt(attrs, "payload.attempt"), "2")
        XCTAssertEqual(boolean(fields(attr(attrs, "payload.ok") ?? .null)["boolValue"]), false)
    }

    func testLogRecordWithoutTraceOmitsIds() throws {
        let record = fields(try OtlpMapper.logRecord(for: entry()))
        XCTAssertNil(record["traceId"])
        XCTAssertNil(record["spanId"])
    }

    func testOperationLogRecordSharesSpanIdWithItsSpan() throws {
        let item = entry(type: "db_query", payload: ["statement": .string("SELECT 1")],
                         traceId: trace, spanId: span)
        let record = fields(try OtlpMapper.logRecord(for: item))
        let spanFields = fields(try XCTUnwrap(OtlpMapper.span(for: item)))
        XCTAssertEqual(text(record["spanId"]), span)
        XCTAssertEqual(text(spanFields["spanId"]), text(record["spanId"]))
    }

    func testPlainLogRecordNeverReferencesAMissingSpan() throws {
        let record = fields(try OtlpMapper.logRecord(for: entry(traceId: trace)))
        XCTAssertEqual(text(record["traceId"]), trace)
        XCTAssertNil(record["spanId"])
    }

    // MARK: - Span

    func testHttpSpanUsesSemanticConventions() throws {
        let item = entry(
            type: "network_request",
            payload: [
                "method": .string("GET"),
                "url": .string("https://api.example.com:8443/orders?page=1"),
                "status_code": .int(200),
                "duration_ms": .int(12),
            ],
            traceId: trace)
        let spanFields = fields(try XCTUnwrap(OtlpMapper.span(for: item)))
        XCTAssertEqual(text(spanFields["name"]), "GET https://api.example.com:8443/orders?page=1")
        XCTAssertEqual(number(spanFields["kind"]), OtlpMapper.spanKindClient)
        XCTAssertEqual(text(spanFields["startTimeUnixNano"]), "1794045600123456789")
        XCTAssertEqual(text(spanFields["endTimeUnixNano"]), "1794045600135456789")
        XCTAssertNil(spanFields["status"], "成功的 span 保持 status UNSET（不写 OK 噪音）")

        let attrs = items(spanFields["attributes"])
        XCTAssertEqual(attrText(attrs, "http.request.method"), "GET")
        XCTAssertEqual(attrInt(attrs, "http.response.status_code"), "200")
        XCTAssertEqual(attrText(attrs, "server.address"), "api.example.com")
        XCTAssertNil(attr(attrs, "error.type"))
    }

    func testFractionalDurationKeepsSubMillisecondPrecision() throws {
        let item = entry(type: "network_request", payload: ["duration_ms": .double(42.5)])
        let spanFields = fields(try XCTUnwrap(OtlpMapper.span(for: item)))
        let start = Int64(text(spanFields["startTimeUnixNano"]) ?? "0") ?? 0
        let end = Int64(text(spanFields["endTimeUnixNano"]) ?? "0") ?? 0
        XCTAssertEqual(end - start, 42_500_000)
    }

    func testHttpFailureSetsErrorStatus() throws {
        let item = entry(
            type: "network_request",
            payload: [
                "method": .string("POST"),
                "url": .string("http://localhost:8080/pay"),
                "status_code": .int(503),
            ])
        let spanFields = fields(try XCTUnwrap(OtlpMapper.span(for: item)))
        XCTAssertEqual(number(fields(spanFields["status"] ?? .null)["code"]), OtlpMapper.statusCodeError)
        XCTAssertEqual(attrText(items(spanFields["attributes"]), "error.type"), "503")
    }

    func testDbSpanPrefersCanonicalStatementKey() throws {
        let item = entry(
            type: "db_query",
            payload: [
                "operation": .string("select"),
                "statement": .string("SELECT 1"),
                "sql": .string("SELECT legacy"),
                "db_system": .string("postgresql"),
            ])
        let spanFields = fields(try XCTUnwrap(OtlpMapper.span(for: item)))
        XCTAssertEqual(text(spanFields["name"]), "select SELECT 1")
        let attrs = items(spanFields["attributes"])
        XCTAssertEqual(attrText(attrs, "db.statement"), "SELECT 1")
        XCTAssertEqual(attrText(attrs, "db.operation"), "select")
        XCTAssertEqual(attrText(attrs, "db.system"), "postgresql")
    }

    func testDbSpanIgnoresLegacySqlAndQueryKeys() throws {
        let legacySql = entry(type: "db_query",
                              payload: ["operation": .string("exec"), "sql": .string("INSERT 1")])
        XCTAssertEqual(text(fields(try XCTUnwrap(OtlpMapper.span(for: legacySql)))["name"]),
                       "exec ")

        let legacyQuery = entry(type: "db_query",
                                payload: ["operation": .string("exec"), "query": .string("INSERT 2")])
        XCTAssertEqual(text(fields(try XCTUnwrap(OtlpMapper.span(for: legacyQuery)))["name"]),
                       "exec ")
    }

    func testNonOperationEventsProduceNoSpan() throws {
        for type in ["log", "ui_interaction", "screen_view", "crash", "hang"] {
            XCTAssertNil(try OtlpMapper.span(for: entry(type: type)), "\(type) 必须留在 logs 信号里")
        }
    }

    func testCrashCarriesExceptionAttributes() throws {
        let record = fields(try OtlpMapper.logRecord(
            for: entry(
                type: "crash",
                payload: [
                    "exception": .string("NSException"),
                    "message": .string("index out of bounds"),
                    "stack": .string("at onClick (app.swift:1)"),
                ],
                agentAuto: true)))
        let attrs = items(record["attributes"])
        XCTAssertEqual(attrText(attrs, "exception.type"), "NSException")
        XCTAssertEqual(attrText(attrs, "exception.message"), "index out of bounds")
        XCTAssertEqual(attrText(attrs, "exception.stacktrace"), "at onClick (app.swift:1)")
        XCTAssertEqual(boolean(fields(attr(attrs, "agent.auto") ?? .null)["boolValue"]), true)
    }

    // MARK: - 批次

    func testResourceGroupsByServiceEnvAndSession() throws {
        let other = AgentLogEntry(
            ts: ts, level: "info", service: "demo-app", subsystem: "", category: "",
            eventType: "log", sessionId: "sess-2", agentAuto: false, message: "c", env: "dev")
        let body = fields(try OtlpMapper.toOtlpLogs([entry(message: "a"), entry(message: "b"), other]))
        let groups = items(body["resourceLogs"])
        XCTAssertEqual(groups.count, 2)

        let first = fields(groups[0])
        let resource = items(fields(first["resource"] ?? .null)["attributes"])
        XCTAssertEqual(attrText(resource, "service.name"), "demo-app")
        XCTAssertEqual(attrText(resource, "deployment.environment"), "prod")
        XCTAssertEqual(attrText(resource, "session.id"), "sess-1")
        XCTAssertEqual(attrText(resource, "telemetry.sdk.name"), "agent-log")
        XCTAssertEqual(attrText(resource, "telemetry.sdk.language"), "swift")
        XCTAssertEqual(attrText(resource, "telemetry.sdk.version"), OtlpMapper.sdkVersion)

        let scopeLogs = fields(items(first["scopeLogs"]).first ?? .null)
        XCTAssertEqual(text(fields(scopeLogs["scope"] ?? .null)["name"]), "agentlog.otlp")
        XCTAssertEqual(items(scopeLogs["logRecords"]).count, 2, "组内保持输入顺序")
    }

    func testExtraResourceCannotOverrideBuiltins() throws {
        let body = fields(try OtlpMapper.toOtlpLogs(
            [entry()],
            extraResource: ["service.name": .string("hijacked"), "service.version": .string("2.1.0")]))
        let resource = items(fields(fields(items(body["resourceLogs"])[0])["resource"] ?? .null)["attributes"])
        XCTAssertEqual(attrText(resource, "service.name"), "demo-app")
        XCTAssertEqual(attrText(resource, "service.version"), "2.1.0")
        let names = resource.compactMap { text(fields($0)["key"]) }.filter { $0 == "service.name" }
        XCTAssertEqual(names.count, 1)
    }

    func testTracesBodySkipsGroupsWithoutOperationEvents() throws {
        let op = entry(type: "network_request",
                       payload: ["method": .string("GET"), "url": .string("http://a/b")])
        let body = fields(try OtlpMapper.toOtlpSpans([entry(), op]))
        let groups = items(body["resourceSpans"])
        XCTAssertEqual(groups.count, 1)
        let spans = items(fields(items(fields(groups[0])["scopeSpans"]).first ?? .null)["spans"])
        XCTAssertEqual(spans.count, 1, "普通日志不产 span")

        let plainOnly = fields(try OtlpMapper.toOtlpSpans([entry()]))
        XCTAssertEqual(items(plainOnly["resourceSpans"]).count, 0)
    }

    func testToOtlpReturnsBothSignalsAndSerializes() throws {
        let both = fields(try OtlpMapper.toOtlp(
            [entry(type: "db_query", payload: ["statement": .string("SELECT 1")])]))
        XCTAssertNotNil(both["logs"])
        XCTAssertNotNil(both["traces"])

        let json = OtlpMapper.json(both["logs"] ?? .null)
        XCTAssertTrue(json.hasPrefix("{") && json.hasSuffix("}"))
        XCTAssertTrue(json.contains("\"timeUnixNano\":\"1794045600123456789\""), "纳秒必须是字符串")
        // 序列化后再解码，结构不变（AgentValue 可往返）
        let decoded = try JSONDecoder().decode(AgentValue.self, from: Data(json.utf8))
        XCTAssertEqual(fields(decoded).count, fields(both["logs"] ?? .null).count)
    }

    func testSdkConstantsMatchSpec() {
        XCTAssertEqual(OtlpMapper.sdkVersion, "1.0.0")
        XCTAssertEqual(OtlpMapper.spanKindClient, 3)
        XCTAssertEqual(OtlpMapper.statusCodeError, 2)
    }
}
