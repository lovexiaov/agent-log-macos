import XCTest
import Logging
@testable import AgentLog

/// 守住 Schema v1（真源：ai-dev-spec `docs/logging-framework/schema/log-event.schema.json`）。
///
/// 规范会随时间腐化——只要线格式字段被无意改成 camelCase、或有人往顶层私加字段，
/// 这条测试就必须失败。跨端一致性靠这条断言 + Web 端同名测试共同保证。
final class SchemaTests: XCTestCase {

    /// Schema v1 顶层必填字段
    private static let requiredKeys: Set<String> = [
        "ts", "level", "service", "event_type", "session_id", "agent_auto", "message",
    ]
    /// Schema v1.1 顶层可选字段（v1.3 增补 `release`）
    private static let optionalKeys: Set<String> = [
        "trace_id", "span_id", "subsystem", "category", "env", "release", "user_id", "payload",
    ]
    /// 历史 camelCase 命名，绝不允许回流到线格式
    private static let legacyKeys: Set<String> = [
        "eventType", "sessionId", "traceId", "agentAuto", "timestamp",
    ]

    private func jsonObject(_ entry: AgentLogEntry) throws -> [String: Any] {
        let data = Data(entry.jsonLine.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jsonLine 必须是合法 JSON 对象")
    }

    private func fullEntry() -> AgentLogEntry {
        AgentLogEntry(
            ts: "2026-11-02T13:37:21.123Z",
            level: "info",
            service: "com.yourapp.agent",
            subsystem: "com.yourapp.agent",
            category: "auto",
            eventType: "network_request",
            sessionId: "s-1",
            traceId: "0123456789abcdef0123456789abcdef",
            agentAuto: true,
            message: "GET https://api.example.com/orders -> 200",
            env: "prod",
            release: "1.4.2",
            payload: ["status": 200, "duration_ms": 128])
    }

    // MARK: - 线格式

    func testWireKeysAreSubsetOfSchemaV1() throws {
        let obj = try jsonObject(fullEntry())
        let allowed = Self.requiredKeys.union(Self.optionalKeys)
        for key in obj.keys {
            XCTAssertTrue(allowed.contains(key), "顶层出现 schema 外字段: \(key)")
        }
        for key in Self.requiredKeys {
            XCTAssertNotNil(obj[key], "缺少必填字段 \(key)")
        }
    }

    func testCamelCaseKeysNeverLeak() throws {
        let obj = try jsonObject(fullEntry())
        for key in Self.legacyKeys {
            XCTAssertNil(obj[key], "线格式泄漏了内部命名 \(key)")
        }
        // 映射后的 snake_case 必须存在且值正确
        XCTAssertEqual(obj["event_type"] as? String, "network_request")
        XCTAssertEqual(obj["session_id"] as? String, "s-1")
        XCTAssertEqual(obj["trace_id"] as? String, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(obj["agent_auto"] as? Bool, true)
    }

    func testPayloadStaysNested() throws {
        let obj = try jsonObject(fullEntry())
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertEqual(payload["status"] as? Int, 200)
        XCTAssertEqual(payload["duration_ms"] as? Int, 128)
        // 业务字段不得被提升到顶层
        XCTAssertNil(obj["status"])
        XCTAssertNil(obj["duration_ms"])
    }

    // MARK: - release（Schema v1.3）

    func testReleaseIsWrittenAsTopLevelField() throws {
        let obj = try jsonObject(fullEntry())
        XCTAssertEqual(obj["release"] as? String, "1.4.2", "release 必须是一等顶层字段，而不是 payload 子键")
        let payload = try XCTUnwrap(obj["payload"] as? [String: Any])
        XCTAssertNil(payload["release"], "release 不得重复写进 payload")
    }

    func testReleaseOmittedWhenAbsentOrInvalid() throws {
        // 未配置 → 不写该键（v1.2 行仍然合法）
        let plain = try jsonObject(AgentLogEntry(
            level: "info", service: "svc", subsystem: "sub", category: "app",
            eventType: "log", sessionId: "s-1", agentAuto: false, message: "hi"))
        XCTAssertNil(plain["release"])

        // 空串 / 超长 → 视同未配置，绝不写出违规行
        for bad in ["", String(repeating: "v", count: 129)] {
            let obj = try jsonObject(AgentLogEntry(
                level: "info", service: "svc", subsystem: "sub", category: "app",
                eventType: "log", sessionId: "s-1", agentAuto: false, message: "hi",
                release: bad))
            XCTAssertNil(obj["release"], "非法 release 应被丢弃: \(bad.prefix(8))…")
        }

        // 边界值 128 必须保留
        let edge = String(repeating: "v", count: 128)
        let obj = try jsonObject(AgentLogEntry(
            level: "info", service: "svc", subsystem: "sub", category: "app",
            eventType: "log", sessionId: "s-1", agentAuto: false, message: "hi",
            release: edge))
        XCTAssertEqual(obj["release"] as? String, edge)
    }

    func testReleaseRoundTripsThroughDecoder() throws {
        let encoded = fullEntry().jsonLine
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(encoded.utf8))
        XCTAssertEqual(decoded.release, "1.4.2")
    }

    // MARK: - level 词表

    func testLevelVocabularyMatchesSchema() {
        let expected: Set<String> = ["trace", "debug", "info", "warn", "error", "critical"]
        for level in [Logging.Logger.Level.trace, .debug, .info, .warning, .error, .critical] {
            XCTAssertTrue(expected.contains(level.agentName), "非法 level: \(level.agentName)")
        }
        // Swift 枚举叫 .warning，但线格式必须写 warn
        XCTAssertEqual(Logging.Logger.Level.warning.agentName, "warn")
        // `warning` 不是规范线格式值，读取时返回 nil
        XCTAssertNil(Logging.Logger.Level(agentName: "warning"))
        XCTAssertEqual(Logging.Logger.Level(agentName: "warn"), .warning)
    }

    // MARK: - 读写往返（Agent 消费 JSONL 依赖它）

    func testDecodeAcceptsSchemaLine() throws {
        let entry = fullEntry()
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(entry.jsonLine.utf8))
        XCTAssertEqual(decoded.eventType, "network_request")
        XCTAssertEqual(decoded.sessionId, "s-1")
        XCTAssertEqual(decoded.traceId, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(decoded.agentAuto, true)
        XCTAssertEqual(decoded.env, "prod")
        XCTAssertEqual(decoded.payload?["status"], .int(200))
    }

    /// 直接吃 docs/logging-framework/schema/example.json 的等价内容，证明规范样例可被本端解析。
    func testDecodeCanonicalExample() throws {
        let json = """
        {"ts":"2026-11-02T13:37:21.123Z","level":"info","service":"com.yourapp.agent",
         "subsystem":"com.yourapp.agent","category":"auto","event_type":"network_request",
         "session_id":"8f14e45fea0a4c1b9c3e0d5b2c7a9e11",
         "trace_id":"3f9a1c2b7d4e4a5b8c9d0e1f2a3b4c5d","span_id":"a1b2c3d4e5f60718",
         "agent_auto":true,"message":"GET https://api.example.com/orders -> 200 (128ms)",
         "env":"prod","release":"1.4.2","payload":{"host":"api.example.com","path":"/orders",
         "method":"GET","status":200,"duration_ms":128}}
        """
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.eventType, "network_request")
        XCTAssertEqual(decoded.sessionId, "8f14e45fea0a4c1b9c3e0d5b2c7a9e11")
        XCTAssertEqual(decoded.agentAuto, true)
        XCTAssertEqual(decoded.release, "1.4.2")
        XCTAssertEqual(decoded.payload?["method"], .string("GET"))
    }

    /// 规范样例里的 crash 事件（docs/logging-framework/schema/example-crash.json）：
    /// 读取侧必须能识别标准异常词表，且 `release` 一并解出。
    func testDecodeCanonicalCrashExample() throws {
        let json = """
        {"ts":"2026-11-02T13:38:05.004Z","level":"critical","service":"com.yourapp.agent",
         "subsystem":"agent.crash","category":"crash","event_type":"crash",
         "session_id":"8f14e45fea0a4c1b9c3e0d5b2c7a9e11",
         "trace_id":"3f9a1c2b7d4e4a5b8c9d0e1f2a3b4c5d","span_id":"b2c3d4e5f6071829",
         "agent_auto":true,"message":"uncaught exception in checkout flow","env":"prod",
         "release":"1.4.2","payload":{"exception":"java.lang.NullPointerException",
         "exception_message":"Attempt to invoke virtual method on a null object reference",
         "stack":"java.lang.NullPointerException: null\\n\\tat Cart.total(Cart.java:42)",
         "mechanism":"uncaught"}}
        """
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.eventType, "crash")
        XCTAssertEqual(decoded.level, "critical")
        XCTAssertEqual(decoded.release, "1.4.2")
        XCTAssertEqual(decoded.payload?["exception"], .string("java.lang.NullPointerException"))
        XCTAssertEqual(decoded.payload?["mechanism"], .string("uncaught"))
    }

    /// 向后兼容：v1.2 及更早的行（无 `release`、非法 trace_id）必须仍能被读取。
    func testDecodeLegacyLineWithoutRelease() throws {
        let json = """
        {"ts":"2026-11-02T13:37:21.123Z","level":"info","service":"com.yourapp.agent",
         "subsystem":"com.yourapp.agent","category":"auto","event_type":"network_request",
         "session_id":"8f14e45f-ea0a-4c1b-9c3e-0d5b2c7a9e11","trace_id":"trace_3f9a1c2b7d4e",
         "agent_auto":true,"message":"GET https://api.example.com/orders -> 200 (128ms)",
         "env":"prod","payload":{"host":"api.example.com","path":"/orders","method":"GET",
         "status":200,"duration_ms":128}}
        """
        let decoded = try JSONDecoder().decode(AgentLogEntry.self, from: Data(json.utf8))
        XCTAssertNil(decoded.release, "历史行没有 release，读取侧不得造值")
        XCTAssertEqual(decoded.eventType, "network_request")
        XCTAssertEqual(decoded.payload?["method"], .string("GET"))
    }
}
